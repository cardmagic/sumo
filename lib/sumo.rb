require 'AWS'
require 'yaml'
require 'socket'
require 'net/ssh'

class Sumo
	def launch
		ami = config['ami']
		raise "No AMI selected" unless ami

		create_keypair unless File.exists? keypair_file

		create_security_group
		open_firewall(22)

		result = ec2.run_instances(
			:image_id => ami,
			:instance_type => config['instance_size'],
			:key_name => 'sumo',
			:security_group => [ 'sumo' ],
			:availability_zone => config['availability_zone']
		)
		result.instancesSet.item[0].instanceId
	end

	def list
		@list ||= fetch_list
	end

	def volumes
		result = ec2.describe_volumes
		return [] unless result.volumeSet

		result.volumeSet.item.map do |row|
			{
				:volume_id => row["volumeId"],
				:size => row["size"],
				:status => row["status"],
				:device => (row["attachmentSet"]["item"].first["device"] rescue ""),
				:instance_id => (row["attachmentSet"]["item"].first["instanceId"] rescue ""),
			}
		end
	end

	def available_volumes
		volumes.select { |vol| vol[:status] == 'available' }
	end

	def attached_volumes
		volumes.select { |vol| vol[:status] == 'in-use' }
	end

	def nondestroyed_volumes
		volumes.select { |vol| vol[:status] != 'deleting' }
	end

	def attach(volume, instance, device)
		result = ec2.attach_volume(
			:volume_id => volume,
			:instance_id => instance,
			:device => device
		)
		"done"
	end

	def detach(volume)
		result = ec2.detach_volume(:volume_id => volume, :force => "true")
		"done"
	end

	def create_volume(size)
		result = ec2.create_volume(
			:availability_zone => config['availability_zone'],
			:size => size.to_s
		)
		result["volumeId"]
	end
	
	def format_volume(volume, instance, device, mountpoint)
		commands = [
			"if [ ! -d #{mountpoint} ]; then sudo mkdir #{mountpoint}; fi",
			"if [ -b /dev/#{device}1 ]; then sudo mount /dev/#{device}1 #{mountpoint}; else echo ',,L' | sudo sfdisk /dev/#{device} && sudo mkfs.xfs /dev/#{device}1 && sudo mount /dev/#{device}1 #{mountpoint}; fi"
		]
		ssh(instance, commands)
  end

	def destroy_volume(volume)
		ec2.delete_volume(:volume_id => volume)
		"done"
	end

	def fetch_list
		result = ec2.describe_instances
		return [] unless result.reservationSet

		instances = []
		result.reservationSet.item.each do |r|
			r.instancesSet.item.each do |item|
				instances << {
					:instance_id => item.instanceId,
					:status => item.instanceState.name,
					:hostname => item.dnsName,
					:local_dns => item.privateDnsName,
					:private_ip => item.privateIpAddress
				}
			end
		end
		instances
	end

	def find(id_or_hostname)
		return unless id_or_hostname
		id_or_hostname = id_or_hostname.strip.downcase
		list.detect do |inst|
			inst[:hostname] == id_or_hostname or
			inst[:instance_id] == id_or_hostname or
			inst[:instance_id].gsub(/^i-/, '') == id_or_hostname
		end
	end

	def find_volume(volume_id)
		return unless volume_id
		volume_id = volume_id.strip.downcase
		volumes.detect do |volume|
			volume[:volume_id] == volume_id or
			volume[:volume_id].gsub(/^vol-/, '') == volume_id
		end
	end

	def running
		list_by_status('running')
	end

	def pending
		list_by_status('pending')
	end

	def list_by_status(status)
		list.select { |i| i[:status] == status }
	end

	def instance_info(instance_id)
		fetch_list.detect do |inst|
			inst[:instance_id] == instance_id
		end
	end

	def wait_for_hostname(instance_id)
		raise ArgumentError unless instance_id and instance_id.match(/^i-/)
		loop do
			if inst = instance_info(instance_id)
				if hostname = inst[:hostname]
					return hostname
				end
			end
			sleep 1
		end
	end

	def wait_for_private_ip(instance_id)
		raise ArgumentError unless instance_id and instance_id.match(/^i-/)
		loop do
			if inst = instance_info(instance_id)
				if private_ip = inst[:private_ip]
					return private_ip
				end
			end
			sleep 1
		end
	end

	def wait_for_ssh(hostname)
		raise ArgumentError unless hostname
		attempts = 0
		loop do
			begin
				Timeout::timeout(4) do
					TCPSocket.new(hostname, 22)
					if attempts < 10
        		attempts += 1
  					IO.popen("ssh -i #{keypair_file} #{config['user']}@#{hostname} > #{config['logfile'] || "~/.sumo/ssh.log"} 2>&1", "w") do |pipe|
        			pipe.puts "ls"
        		end
      		else
      		  return false
    		  end
      		if $?.success?
      			return true
      		else
      		  sleep 5
    		  end
				end
			rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH
			end
		end
	end

	def bootstrap_chef(hostname)
		commands = [
			'sudo apt-get update',
			'sudo apt-get autoremove -y',
			'if [ ! -f /usr/lib/ruby/1.8/net/https.rb ]; then sudo apt-get install -y xfsprogs xfsdump xfslibs-dev ruby ruby-dev rubygems libopenssl-ruby1.8 git-core; fi',
			'if [ ! -d /etc/chef ]; then sudo mkdir /etc/chef; fi',
			'if [ ! -d /var/lib/gems/1.8/gems/chef-* ]; then sudo gem install chef ohai --no-rdoc --no-ri; fi',
			config['cookbooks_url'] ? "if [ -d chef-cookbooks ]; then cd chef-cookbooks; git pull; else git clone #{config['cookbooks_url']} chef-cookbooks; fi" : "echo done"
		]
		ssh(hostname, commands)
		if !config['cookbooks_url'] && config['cookbooks_dir']
		  scp(hostname, config['cookbooks_dir'], "chef-cookbooks")
	  end
	  if config['chef-validation']
	    scp(hostname, config['chef-validation'], "validation.pem")
	    ssh(hostname, ["sudo mv validation.pem /etc/chef/"])
    end
	end

	def setup_role(hostname, instance_id, role)
		commands = [
		  "if [ ! -f /etc/chef/client.pem ]; then cd chef-cookbooks",
			"sudo /var/lib/gems/1.8/bin/chef-solo -c config/solo.rb -j roles/bootstrap.json -r http://s3.amazonaws.com/chef-solo/bootstrap-latest.tar.gz",
			"if [ -f config/client.rb ]; then sudo cp config/client.rb /etc/chef/client.rb; fi",
			"sudo /var/lib/gems/1.8/bin/chef-client",
			"sudo rm /etc/chef/validation.pem; fi"
		]
		ssh(hostname, commands)
		`knife node run_list add #{instance_id} "role[#{role}]"`
		ssh(hostname, ["sudo /var/lib/gems/1.8/bin/chef-client"])
	end

	def ssh(hostname, cmds)
	  unless IO.read(File.expand_path("~/.ssh/known_hosts")).include?(hostname)
	    `ssh-keyscan -t rsa #{hostname} >> $HOME/.ssh/known_hosts`
	    if config['deploy_key']
	      scp(hostname, config['deploy_key'], ".ssh/id_rsa")
      end
      if config['known_hosts']
        scp(hostname, config['known_hosts'], ".ssh/known_hosts")
      end
    end
		IO.popen("ssh -i #{keypair_file} #{config['user']}@#{hostname} > #{config['logfile'] || "~/.sumo/ssh.log"} 2>&1", "w") do |pipe|
			pipe.puts cmds.join(' && ')
		end
		unless $?.success?
			raise "failed\nCheck #{config['logfile'] || "~/.sumo/ssh.log"} for the output"
		end
	end

	def scp(hostname, directory, endpoint=".")
		`scp -i #{keypair_file} -r #{directory} #{config['user']}@#{hostname}:#{endpoint}`
		unless $?.success?
			raise "failed to transfer #{directory}"
		end
	end

	def new_ssh(hostname, cmds)
    Net::SSH.start(hostname, config['user'], :keys => [keypair_file], :compression => "none") do |ssh|
      # capture all stderr and stdout output from a remote process
            
      File.open(File.expand_path("~/.sumo/ssh.log"), "w") do |log|
        ssh.open_channel do |channel|          
          cmds.each do |cmd|
            channel.exec cmd do |ch, success|
        			raise "failed on #{cmd}\nCheck ~/.sumo/ssh.log for the output" unless success

              channel.on_data do |ch, data|
                puts "Got data #{data.inspect}"
                log << data
                log.flush
              end

              channel.on_extended_data do |ch, type, data|
                puts "Got data #{data.inspect}"
                log << data
                log.flush
              end
              
              channel.on_close do |ch|
                puts "channel is closing!"
              end
            end
          end
        end

        ssh.loop
      end
    end
	end

	def resources(hostname)
		@resources ||= {}
		@resources[hostname] ||= fetch_resources(hostname)
	end

	def fetch_resources(hostname)
		cmd = "ssh -i #{keypair_file} #{config['user']}@#{hostname} 'sudo cat /root/resources' 2>&1"
		out = IO.popen(cmd, 'r') { |pipe| pipe.read }
		raise "failed to read resources, output:\n#{out}" unless $?.success?
		parse_resources(out, hostname)
	end

	def parse_resources(raw, hostname)
		raw.split("\n").map do |line|
			line.gsub(/localhost/, hostname)
		end
	end

	def terminate(instance_id)
		ec2.terminate_instances(:instance_id => [ instance_id ])
	end

	def console_output(instance_id)
		ec2.get_console_output(:instance_id => instance_id)["output"]
	end

	def config
		@config ||= default_config.merge read_config
	end

	def set(key, value)
		config[key] = value
	end

	def default_config
		{
			'user' => 'ubuntu',
			'ami' => 'ami-1234de7b', # Ubuntu 10.04 LTS (Lucid Lynx)
			'availability_zone' => 'us-east-1d',
			'instance_size' => 't1.micro'
		}
	end

	def sumo_dir
		"#{ENV['HOME']}/.sumo"
	end

	def read_config
		YAML.load File.read("#{sumo_dir}/config.yml")
	rescue Errno::ENOENT
		raise "Sumo is not configured, please fill in ~/.sumo/config.yml"
	end

	def keypair_file
		"#{sumo_dir}/keypair.pem"
	end

	def create_keypair
		keypair = ec2.create_keypair(:key_name => "sumo").keyMaterial
		File.open(keypair_file, 'w') { |f| f.write keypair }
		File.chmod 0600, keypair_file
	end

	def create_security_group
		ec2.create_security_group(:group_name => 'sumo', :group_description => 'Sumo')
	rescue AWS::InvalidGroupDuplicate
	end

	def open_firewall(port)
		ec2.authorize_security_group_ingress(
			:group_name => 'sumo',
			:ip_protocol => 'tcp',
			:from_port => port,
			:to_port => port,
			:cidr_ip => '0.0.0.0/0'
		)
	rescue AWS::InvalidPermissionDuplicate
	end

	def ec2
    @ec2 ||= AWS::EC2::Base.new(
      :access_key_id => config['access_id'], 
      :secret_access_key => config['access_secret'], 
      :server => server
    )
	end
	
	def server
	  zone = config['availability_zone']
	  host = zone.slice(0, zone.length - 1)
	  "#{host}.ec2.amazonaws.com"
  end
end
