dhcp-mod
========

Ruby script to manage dhcp reservations file

=======

dhcp-mod.rb
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
