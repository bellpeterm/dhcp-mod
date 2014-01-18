#!/usr/bin/ruby

##### Required libraries #####

require 'rubygems'
require 'ipaddress'
#require 'MACAddr'
require 'ftools'
require 'getopt/long.rb'

##### Classes and other definitions #####

class Dhcpconf
	
	public
	# define instance variables
	# @config - string to contain entirety of the original text config file
	# @supernet - IPAddress object that defines IP space for use by subnets
	# @subnet_size - the default number of hosts needed in a new subnet
	# @subnet_gateway - first or last, default placing for gateway of new subnets
	attr_accessor :config, :supernet, :subnet_size, :subnet_gateway
	
	# reads the configuration file into @config and parses reservations and subnets
	def initialize(config_file)
		read_configuration(config_file)
		parse_configuration
	end
	
	# reads the configuration file into @config
	def read_configuration(config_file)
		#read configuration file into memory
		@config = File.open(config_file, 'rb') { |f| f.read }
		#another option config_lines = File.readlines(config_file) config = config_lines.join
	end
	
	# writes the configuration to a new file, backs up then replaces the exisiting file with the new one
	def write_configuration_file(config_file) #OUTPUT: writes modified configuration file and backs up old
		# creates the new configuration file
		newconfig = File.open(config_file + ".new", 'w')
		
		# writes the Dhcpconf variables, then writes the subnets and reservations to the new file
		newconfig.write "###General Configuration\n"
		write_config(newconfig)
		newconfig.write "\n###Subnets and Reservations\n"
		Subnet.subnets.each { |subnet| subnet.write(newconfig) }
		
		# closes the new file's filehandle
		newconfig.close
		
		# backs up and replaces the old configuration file with the new one
		File.copy(config_file , config_file + ".bak")
		File.move(config_file + ".new" , config_file)
	end
	
	# writes the global variables to the output specified in their parseable format
	def write_config(output) #OUTPUT: write general configuration to output
		output.puts "##\@supernet=#{@supernet.network.to_s + "/" + @supernet.prefix.to_s}"
		output.puts "##\@subnet_size=#{@subnet_size.to_s}"
		output.puts "##\@subnet_gateway=#{@subnet_gateway.to_s}"
	end
	
	# parses and assigns the Dhcpconf variables, then parses the existing subnets and reservations
	def parse_configuration #read the configuration parameters and parse data		
		# supernet is a CIDR formatted IP block, assigned as an IPAddress object
		supernet = @config.match(/^##\@supernet=(.*?)$/)
		@supernet = IPAddress(supernet[1])
		#subnet_size is an integer, the number of hosts needed for a subnet
		subnet_size = @config.match(/^##\@subnet_size=(.*?)$/)
		@subnet_size = subnet_size[1].to_i
		#subnet_gateway is the string "first" or "last"
		subnet_gateway = @config.match(/^##\@subnet_gateway=(.*?)$/)
		@subnet_gateway = subnet_gateway[1]
		
#		Subnet.subnets = Array.new
#		Reservation.reservations = Array.new
		
		# parse subnet configurations and create subnet objects, returns all
		# # subnet => # end strings into the subnets arrays
		subnets = @config.scan(/# subnet.*?# end/m)
		if subnets.count > 0
			# iterate over the subnets returned and create a subnet for each one
			subnets.each do |subnet_config|
				subnet = Subnet.new
				# parse the 5 comma-separated values that makeup the individual subnet config
				configuration_fields = subnet_config.match(/subnet - (.*)$/)[1]
				subnet_configuration = configuration_fields.split(",")
				subnet.name = subnet_configuration[0]
				if subnet_configuration[1]
					subnet.ipv4subnet = IPAddress(subnet_configuration[1])
					subnet.ipv4gateway = IPAddress(subnet_configuration[2])
				end
				if subnet_configuration[3]
					subnet.ipv6subnet = IPAddress(subnet_configuration[3])
					subnet.ipv6gateway = IPAddress(
								       subnet_configuration[4])
				end
				Subnet.subnets << subnet
				reservations = subnet_config.scan(/host.*?\}/m)
				if reservations.count > 0
					reservations.each do |reservation_config|
						reservation = Reservation.new
						reservation.hostname = reservation_config.match(/host (\S+)/)[1]
						reservation.ipv4addr = IPAddress("#{reservation_config.match(/fixed-address ((?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))/)[1]}")
#						reservation.ipv6addr = IPAddress("#{reservation_config.match(/fixed-address6 ([0-9a-fA-F:]+?)/)[1]}")
						reservation.macaddr = reservation_config.match(/hardware ethernet ((?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})/)[1]
						Reservation.reservations << reservation
				end
				end
			end
		end
	end

end

class Subnet
	public
	attr_accessor :name, :ipv4gateway, :ipv6gateway, :ipv4subnet, :ipv6subnet
	@@subnets = Array.new
	def Subnet.subnets
		@@subnets
	end
	def Subnet.search(search_string) #INPUT: ip address or hostname; OUTPUT: returns found_subnet containing the found subnet object
		#search subnets by ip address or name and return containing object
		found_subnet = Array.new
		if IPAddress.valid_ipv4?(search_string)
			found_subnet = Subnet.subnets.find_all do |net|
				net.ipv4subnet.include? IPAddress(search_string)
			end
		elsif IPAddress.valid_ipv6?(search_string)
			found_subnet = Subnet.subnets.find_all do |net|
				net.ipv6subnet.include? IPAddress(search_string)
			end
		else
			found_subnet = Subnet.subnets.find_all { |net| net.name =~ /#{search_string}/ }
		end
		found_subnet
	end
	def Subnet.check_avaliability(net) #INPUT: ipaddress single or block; OUTPUT: true if subnet available for use
		#do a regular search for an ip within an existing subnet then confirm the the new subnet wouldn't overlap and existing subnet by checking in reverse
		if Subnet.search(net.address).count > 0 or Subnet.subnets.find { |existing_net| net.include?(existing_net.ipv4subnet) }
			false
		else
			true
		end
	end

	def Subnet.check_name_availability(name) #INPUT: subnet name; OUTPUT: true if name available for use
		if search_subnets(name)
			false
		else
			true
		end
	end

	def Subnet.create(supernet,size,*name) #INPUT: req size; opt name, gateway; OUTPUT: subnet appends to @@subnets
		#determines a free subnet with (size) number of hosts available excluding gateway
		mask_size = Subnet.determine_netmask_size(size)
		possible_subnets = supernet.subnet(mask_size)
		new_net = possible_subnets.find do |net|
			Subnet.check_avaliability(net)
		end
						
		#create the subnet, set cidr address
		new_subnet = Subnet.new
		new_subnet.ipv4subnet = new_net
		
		subnet_gateway = String.new
		subnet_name = String.new
		#parse *name, which optionally includes a name for the subnet and at least one but optionally two gateways
		name.each do |string|
			if string == "first" or string == "last"
				subnet_gateway = string
			else
				subnet_name = string
			end
		end
		
		#check subnet name for availability or assign subnet network address if no name supplied
		subnet_name = new_net.to_s unless subnet_name
				
		existing_subnet = Subnet.search(subnet_name)
		if existing_subnet.count > 0
			puts "Subnet Exists"
			puts existing_subnet.each { |net| net.formatted }
			exit 1
		end
		
		new_subnet.name = subnet_name
		
		#set the IPv4 gateway
		if new_subnet.ipv4subnet
			if subnet_gateway == "first"
				new_subnet.ipv4gateway = new_subnet.ipv4subnet.first
			elsif subnet_gateway == "last"
				new_subnet.ipv4gateway = new_subnet.ipv4subnet.last
			else
				puts "Invalid IPv4 gateway: #{@subnet_gateway}"
				exit(integer=1)
			end
		end
		
		#set the IPv6 gateway
		if new_subnet.ipv6subnet
			if subnet_gateway == "first"
				new_subnet.ipv6gateway = new_subnet.ipv6subnet.first
			elsif subnet_gateway == "last"
				new_subnet.ipv6gateway = new_subnet.ipv6subnet.last
			else
				puts "Invalid IPv6 gateway: #{@subnet_gateway}"
				exit(integer=1)
			end
		end
		
		#append to subnets array and return subnet
		Subnet.subnets << new_subnet
		new_subnet.formatted
	end
	def Subnet.determine_netmask_size(needed_hosts) #INPUT: number of needed_hosts; OUTPUT: creates @mask_size for needed netmask size
		case
		when needed_hosts < 1
			puts "Subnet size #{needed_hosts} not supported"
			exit
		when needed_hosts < 2
			@mask_size = 30
		when needed_hosts < 6
			@mask_size = 29
		when needed_hosts < 14
			@mask_size = 28
		when needed_hosts < 30
			@mask_size = 27
		when needed_hosts < 62
			@mask_size = 26
		when needed_hosts < 126
			@mask_size = 25
		when needed_hosts < 254
			@mask_size = 24
		when needed_hosts < 510
			@mask_size = 23
		when needed_hosts < 1022
			@mask_size = 22
		when needed_hosts < 2046
			@mask_size = 21
		when needed_hosts < 4094
			@mask_size = 20
		when needed_hosts < 8190
			@mask_size = 19
		when needed_hosts < 16382
			@mask_size = 18
		when needed_hosts < 32766
			@mask_size = 17
		when needed_hosts < 65534
			@mask_size = 16
		else
			puts "Subnet size #{needed_hosts} not supported"
			exit
		end
	end
	
	def Subnet.determine_max_hosts(subnet_prefix) #INPUT: CIDR prefix; OUTPUT: greatest number of hosts available
		case
		when subnet_prefix > 30
			puts "Subnet prefix #{subnet_prefix} not supported"
			exit
		when subnet_prefix == 30
			@max_hosts = 1
		when subnet_prefix == 29
			@max_hosts = 5
		when subnet_prefix == 28
			@max_hosts = 13
		when subnet_prefix == 27
			@max_hosts = 29
		when subnet_prefix == 26
			@max_hosts = 61
		when subnet_prefix == 25
			@max_hosts = 125
		when subnet_prefix == 24
			@max_hosts = 253
		when subnet_prefix == 23
			@max_hosts = 509
		when subnet_prefix == 22
			@max_hosts = 1021
		when subnet_prefix == 21
			@max_hosts = 2045
		when subnet_prefix == 20
			@max_hosts = 4093
		when subnet_prefix == 19
			@max_hosts = 8189
		when subnet_prefix == 18
			@max_hosts = 16381
		when subnet_prefix == 17
			@max_hosts = 32765
		when subnet_prefix == 16
			@max_hosts = 65533
		else
			puts "Subnet size #{needed_hosts} not supported"
			exit
		end
		@max_hosts
	end




	def Subnet.delete(identifier) #INPUT: ipaddress or subnet name; OUTPUT: deletes corresponding subnet from @subnets
		to_be_removed_subnets = Subnet.search(identifier)
		if to_be_removed_subnets.count > 0
			puts "The following subnet(s) and reservation(s) are being removed:"
			to_be_removed_subnets.each do |subnet|
				subnet.formatted
				subnet.hosts
			end
			to_be_removed_subnets.each do |deletable|
				Subnet.subnets.delete(deletable)
			end
		else
			puts "No subnets specified for removal."
			exit 0
		end
		# NOTE: Since the output file only writes reservations that are part of an existing subnet, this implicitly deletes all reservations in the subnet.

	end
	def write(output) #OUTPUT: write given subnet to output
		if @ipv4subnet and @ipv6subnet
		output.write "\n# subnet - #{@name + "," + @ipv4subnet.to_s + "/" + @ipv4subnet.prefix.to_s + "," + @ipv4gateway + "," + @ipv6subnet.to_s + "/" + @ipv6subnet.prefix + "," + @ipv6gateway }\n"
		elsif @ipv4subnet
			output.write "\n# subnet - #{@name + "," + @ipv4subnet.to_s + "/" + @ipv4subnet.prefix.to_s + "," + @ipv4gateway.to_s + "," + "," }\n"
		elsif @ipv6subnet
			output.write "\n# subnet - #{@name + "," + "," + "," + @ipv6subnet.to_s + "/" + @ipv6subnet.prefix + "," + @ipv6gateway }\n"
		end
		subnet_reservations = Reservation.reservations.find_all do
			|res| @ipv4subnet.include?(res.ipv4addr)
		end
		subnet_reservations.each { |reservation| reservation.write(self,output) }
		output.write "\n# end #{@name}\n"
		
	end

	def formatted #output subnet details nicely formatted
		
		puts "\nSubnet Name: #{@name}
IPv4 Address: #{if @ipv4subnet ; @ipv4subnet.network.address + '/' + @ipv4subnet.prefix.to_s end}
IPv4 Gateway: #{if @ipv4gateway ; @ipv4gateway.address end }
IPv6 Address: #{if @ipv6subnet ; @ipv6subnet.network.address + '/' + @ipv6subnet.prefix.to_s end}
IPv6 Gateway: #{if @ipv6gateway ; @ipv6gateway.address end }
Max Hosts: #{if @ipv4subnet
			Subnet.determine_max_hosts(@ipv4subnet.prefix)
		elsif @ipv6subnet
			Subnet.determine_max_hosts(@ipv6subnet.prefix)
		end}"
	end
	
	def hosts
		Reservation.reservations.each do |reservation|
			if @ipv4subnet and @ipv6subnet
				if @ipv4subnet.include? reservation.ipv4addr or @ipv6subnet.include? reservation.ipv6addr
					reservation.formatted
				end
			elsif @ipv4subnet
				if @ipv4subnet.include? reservation.ipv4addr
					reservation.formatted
				end
			elsif @ipv6subnet	
				if @ipv4subnet.include? reservation.ipv4addr or @ipv6subnet.include? reservation.ipv6addr
					reservation.formatted
				end
			end
		end
	end
end

class Reservation
	public
	attr_accessor :hostname ,:macaddr, :ipv4addr, :ipv6addr
	@@reservations = Array.new
	def Reservation.reservations
		@@reservations
	end
	def Reservation.search(search_string) #INPUT: macaddress, hostname or ip address; OUTPUT: creates @found_reservation containing the found reservation object
		#search reservations by MAC address or hostname
		found_reservations = Array.new
		if search_string =~ /^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/
			found_reservations = Reservation.reservations.find_all do |res|
				res.macaddr =~ /#{search_string}/
			end
		elsif IPAddress.valid_ipv4?(search_string)
			found_reservations = Reservation.reservations.find_all do |res|
				res.ipv4addr.address == IPAddress(search_string).address
			end
		elsif IPAddress.valid_ipv6?(search_string) and search_string =~ /:/
			found_reservations = Reservation.reservations.find_all do |res|
				res.ipv6addr.address == IPAddress(search_string).address
			end
		else
			found_reservations = Reservation.reservations.find_all { |res| res.hostname =~ /#{search_string}/ }
		end
		found_reservations
	end
	
	def Reservation.create(macaddress, subnet, *name) #INPUT: req macaddress, subnet; opt name; OUTPUT: @new_res appended to @reservations
		
		#check for existing reservation, print existing
		existing_res = Reservation.search(macaddress)
		if existing_res[0]
			puts "Reservation exists"
			puts existing_res[0].formatted
			exit
		end
		
		#determine a free ip address in the subnet
		ipv4address = Array.new
		if subnet.ipv4subnet
			subnet.ipv4subnet.hosts.each do |ipaddress|
				unless subnet.ipv4gateway.address == ipaddress.address or Reservation.search(ipaddress.address)[0]
					ipv4address << ipaddress
				end
			end
		end
		
		#determine a free ip address in the subnet
		ipv6address = Array.new
		if subnet.ipv6subnet
			subnet.ipv6subnet.hosts.each do |ipaddress|
				unless subnet.ipv6gateway.address == ipaddress.address or Reservation.search(ipaddress.address)[0]
					ipv6address << ipaddress
				end
			end
		end
		
		unless ipv4address[0] or ipv6address[0]
			puts "No available IP space in subnet"
			exit
		end
		
		if name[0]
			name = name[0]
		else
			name = ipaddr.address
		end
		
		#create reservation and add to @@reservations
		new_res = Reservation.new
		new_res.macaddr = macaddress
		new_res.hostname = name
		new_res.ipv4addr = ipv4address[0]
		new_res.ipv6addr = ipv6address[0]
		Reservation.reservations << new_res
		new_res.formatted
	end
	def Reservation.delete(identifier) #INPUT: macaddress, ipaddress, or hostname; OUTPUT deletes corresponding reservations from @reservations
		
		to_be_removed_reservations = Reservation.search(identifier)
		if to_be_removed_reservations.count > 0
			puts "The following reservation(s) are being removed:"
			to_be_removed_reservations.each do |reservation|
				reservation.formatted
			end
			to_be_removed_reservations.each do |deletable|
				Reservation.reservations.delete(deletable)
			end
			else
				puts "No reservations specified for removal."
				exit 0
		end
	end
	def write(subnet,output) #OUTPUT: write given reservation to output
		output.write "\nhost #{@hostname} {
		hardware ethernet #{@macaddr}.;
		fixed-address #{@ipv4addr.address};
		option routers #{subnet.ipv4gateway.address};
		option broadcast-address #{subnet.ipv4subnet.broadcast.address};
		option subnet-mask #{subnet.ipv4subnet.netmask};
		}\n"
	end
	def formatted #output reservation details nicely formatted
		puts "\n	Hostname:     #{@hostname}
	Mac Address: #{@macaddr}
	IPv4 Address: #{@ipv4addr}
	IPv6 Address: #{@ipv6addr}"
	end
end
	
##### Workflow #####

opt = Getopt::Long.getopts(
    ["--subnet", Getopt::BOOLEAN],
    ["--host", Getopt::BOOLEAN],
    ["--add", "-a", Getopt::BOOLEAN],
    ["--remove", "-r", Getopt::REQUIRED],
    ["--show", "-s", Getopt::BOOLEAN],
    ["--identifier", "-i", Getopt::REQUIRED],
    ["--hosts", "-H", Getopt::BOOLEAN],
    ["--help", "--usage", "-h", Getopt::BOOLEAN],
    ["--all", "-a", Getopt::BOOLEAN],
    ["--gateway", "-g", Getopt::REQUIRED],
    ["--file", "-f", Getopt::REQUIRED],
    ["--size", "-S", Getopt::REQUIRED],
    ["--name", "-n", Getopt::REQUIRED],
    ["--network", "-N", Getopt::REQUIRED]
  )

if opt["help"].to_s
	puts "      dhcp-mod.rb
      usage:  dhcp-mod --subnet --add [--name <subnet name>] [--size <subnet size>]
              dhcp-mod --subnet --remove <ip address | subnet name>
              dhcp-mod --subnet --show [--identifier <ip address | subnet name>] [-H | --hosts] [-g | --gateway] [-a | --all]
              dhcp-mod --host --add --identifier <MAC address> --network <subnet name> [--name <hostname>]
              dhcp-mod --host --remove <hostname | MAC address>
              dhcp-mod --host --show [--identifier <hostname | MAC address>] [-a | --all]

              Options:
              -f <filename>
              -h | --help | --usage
		
      Currently requires an existing configuration file.  Functionality to begin a new configuration file to be built later.
	"
	exit 0
end

unless opt.has_key?("file")
	opt["file"] = "dhcpd.conf-3"
end
dhcpd_conf = Dhcpconf.new(opt["file"])
if opt["subnet"]
	if opt["add"]
	#set variables and run necessary methods		
		if opt["size"] and opt["name"] and opt["gateway"]
			Subnet.create(dhcpd_conf.supernet,opt["size"],opt["name"],opt["gateway"])
		elsif opt["size"] and opt["gateway"]
			Subnet.create(dhcpd_conf.supernet,opt["size"],opt["gateway"])
		elsif opt["name"] and opt["gateway"]
			Subnet.create(dhcpd_conf.supernet,dhcpd_conf.subnet_size,opt["name"],opt["gateway"])
		elsif opt["size"] and opt["name"]
			Subnet.create(dhcpd_conf.supernet,opt["size"],opt["name"],dhcpd_conf.subnet_gateway)
		elsif opt["size"]
			Subnet.create(dhcpd_conf.supernet,opt["size"],dhcpd_conf.subnet_gateway)
		elsif opt["name"]
			Subnet.create(dhcpd_conf.supernet,dhcpd_conf.subnet_size,opt["name"],dhcpd_conf.subnet_gateway)
		elsif opt["gateway"]
			Subnet.create(dhcpd_conf.supernet,dhcpd_conf.subnet_size,opt["gateway"])
		else
			Subnet.create(dhcpd_conf.supernet,dhcpd_conf.subnet_size,dhcpd_conf.subnet_gateway)
		end
	elsif opt["remove"]
	#set variables and run necessary methods
		Subnet.delete(opt["remove"])
	elsif opt["show"]
	#set variables and run necessary methods
		if opt["identifier"]
			display_subnet = Subnet.search(opt["identifier"])
			display_subnet.each do |display|
				display.formatted
				if opt["hosts"]
					display.hosts
				end
			end
		else
			if opt["hosts"]
				Subnet.subnets.each do |display_subnet|
					display_subnet.formatted
					display_subnet.hosts
				end
			else
				Subnet.subnets.each do |display_subnet|
					display_subnet.formatted
				end
			end
		end
		exit 0
	end
elsif opt["host"]
	if opt["add"]
	#set variables and run necessary methods
		append_subnet = Subnet.search(opt["network"])
		if append_subnet.count > 1
			puts "Network name ambiguous"
			exit 0
		end
		if opt["name"]
			Reservation.create(opt["identifier"],append_subnet[0],opt["name"])
		else
			Reservation.create(opt["identifier"],append_subnet[0])
		end
	elsif opt["remove"]
	#set variables and run necessary methods
		Reservation.delete(opt["remove"])
	elsif opt["show"]
	#set variables and run necessary methods
		if opt["identifier"]
			display_reservation = Reservation.search(opt["identifier"])
			unless display_reservation.count < 1
				display_reservation.each do |formatted_res|
					formatted_res.formatted
				end
			end
		else
			Reservation.reservations.each do |display_reservation|
				display_reservation.formatted
			end				
		end
		exit 0
	end
else
	puts "Unrecognized command"
	exit 1
end
dhcpd_conf.write_configuration_file(opt["file"])
