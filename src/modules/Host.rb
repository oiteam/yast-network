# encoding: utf-8

# ***************************************************************************
#
# Copyright (c) 2012 Novell, Inc.
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.   See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail,
# you may find current contact information at www.novell.com
#
# **************************************************************************
#
require "yast"
require "yast2/execute"
require "cfa/hosts"

module Yast
  class HostClass < Module
    def main
      Yast.import "UI"
      textdomain "network"

      Yast.import "DNS"
      Yast.import "Hostname"
      Yast.import "NetworkInterfaces"
      Yast.import "String"
      Yast.import "Summary"

      Yast.include self, "network/routines.rb"

      # Data was modified?
      @modified = false

      @initialized = false

      @hosts = CFA::Hosts.new
    end

    # Remove all entries from the host table.
    def clear
      @hosts.hosts.keys.each do |ip|
        @hosts.delete_by_ip(ip)
      end
      @modified = true
    end

    # @return [hash] address->list of names
    def name_map
      @hosts.hosts
    end

    # @return [array] names for that address
    def names(address)
      @hosts.host(address) || []
    end

    # remove all instances of ip in hosts table
    def remove_ip(address)
      @hosts.delete_by_ip(address)
    end

    # Add another name to the list for address (which may be empty so far)
    # FIXME: used only in one place, which looks wrong
    def add_name(address, name)
      canonical, *aliases = name.split(" ")
      @hosts.add_entry(address, canonical, aliases)

      @modified = true
    end

    def NeedDummyIP
      DNS.write_hostname
    end

    def EnsureHostnameResolvable
      local_ip = "127.0.0.2"
      if NeedDummyIP()
        Builtins.y2milestone("Dummy 127.0.0.2 IP will be added")
        # Add 127.0.0.2 entry to /etc/hosts,if product default says so
        # or user requests it otherwise some desktop apps may hang,
        # being unable to resolve hostname (bnc#304632)

        fqhostname = Hostname.MergeFQ(DNS.hostname, DNS.domain)
        set_names(local_ip, ["#{fqhostname} #{DNS.hostname}"])
      elsif @hosts.include_ip?(local_ip)
        # Do not add it if product default says no
        # and remove 127.0.02 entry if it exists

        @hosts.delete_by_ip(local_ip)
      end
      @modified = true

      nil
    end

    # Read hosts settings
    # @return true if success
    def Read
      return true if @initialized

      # read /etc/hosts
      if Ops.greater_than(SCR.Read(path(".target.size"), CFA::Hosts::PATH), 0)
        @hosts = CFA::Hosts.new
        @hosts.load
      end

      # save hosts to check for changes later
      @hosts_init = CFA::Hosts.new
      @hosts_init.load

      Builtins.y2debug("hosts=#{@hosts.inspect}")
      @initialized = true
      true
    end

    # Write hosts settings and apply changes
    # @return true if success
    def Write
      Builtins.y2milestone("Writing hosts configuration")

      if !@modified
        Builtins.y2milestone("No changes to Host -> nothing to write")
        return true
      end

      # Check if there is anything to do
      if @hosts_init == @hosts
        Builtins.y2milestone("Hosts not modified")
        return true
      end

      steps = [_("Update /etc/hosts")]

      caption = _("Saving Hostname Configuration")

      Progress.New(caption, " ", steps.size, steps, [], "")

      ProgressNextStage(_("Updating /etc/hosts ..."))

      # backup if exists
      if SCR.Read(path(".target.size"), CFA::Hosts::PATH) >= 0
        Yast::Execute.on_target("cp", CFA::Hosts::PATH, "#{CFA::Hosts::PATH}.YaST2save")
      end

      @hosts.save

      Progress.NextStage

      true
    end

    # Get all the Hosts configuration from a map.
    # When called by hosts_auto (preparing autoinstallation data)
    # the map may be empty.
    # @param [Hash] settings autoinstallation settings
    # @return true if success
    def Import(settings)
      @modified = true # trigger Write
      @initialized = true # don't let Read discard our data

      @hosts = CFA::Hosts.new
      imported_hosts = Builtins.eval(Ops.get_map(settings, "hosts", {}))

      # convert from old format to the new one
      # use ::1 entry as a reference
      if (imported_hosts["::1"] || []).size > 1
        imported_hosts.each_pair do |k, v|
          imported_hosts[k] = v.join(" ")
        end
      end

      imported_hosts.each_pair do |ip, names|
        set_names(ip, names)
      end

      true
    end

    # Dump the Hosts settings to a map, for autoinstallation use.
    # @return autoinstallation settings
    def Export
      exported_hosts = @hosts.hosts
      return {} if exported_hosts.empty?

      # Filter out IPs with empty hostname (so that valid autoyast
      # profile is created)(#335120)
      exported_hosts.keep_if { |_, names| !names.empty? }

      { "hosts" => exported_hosts }
    end

    # Return "system" predefined hosts (should be present all the time)
    # @return [Array] of system hosts
    def GetSystemHosts
      [
        "127.0.0.1",
        "::1",
        "fe00::0",
        "ff00::0",
        "ff02::1",
        "ff02::2",
        "ff02::3"
      ]
    end

    # Update hosts according to the current hostname
    # (only one hostname, assigned to all IP)
    # @param hostname current hostname
    # @param domain current domain name
    # @param String ip to assign
    # @return true if success
    def Update(oldhn, newhn, ip)
      Builtins.y2milestone(
        "Updating /etc/hosts: %1 -> %2: %3",
        oldhn,
        newhn,
        ip
      )
      @modified = true

      # Remove old hostname from hosts
      @hosts.delete_hostname(oldhn) if !oldhn.empty?

      # Add localhost if missing
      if @hosts.host("127.0.0.1").empty?
        @hosts.add_entry("127.0.0.1", "localhost")
      end

      # Omit some IP addresses
      return true if ["127.0.0.1", "", nil].include?(ip)
      # Omit invalid newhn
      return true if [nil, ""].include?(newhn)

      nick = Hostname.SplitFQ(newhn)[0] || ""
      nick = nick.empty? ? [] : [nick]
      hosts = @hosts.host(ip)
      if hosts.empty?
        @hosts.add_entry(ip, newhn, nick)
      else
        canonical, *aliases = hosts.last.split(" ")
        aliases << newhn
        aliases.concat(nick)
        @hosts.set_entry(ip, canonical, aliases)
      end

      true
    end

    # Create summary
    # @return summary text
    def Summary
      summary = ""
      return Summary.NotConfigured if @hosts.hosts.empty?

      summary = Summary.OpenList(summary)
      @hosts.hosts.each do |k, v|
        Builtins.foreach(v) do |hn|
          summary = Summary.AddListItem(summary, Ops.add(Ops.add(k, " - "), hn))
        end if !Builtins.contains(
          GetSystemHosts(),
          k
        )
      end
      summary = Summary.CloseList(summary)
      summary
    end

    def StaticIPs
      NetworkInterfaces.Read
      devs = NetworkInterfaces.Locate("BOOTPROTO", "static")
      devs = Builtins.filter(devs) { |dev| dev != "lo" }
      ips = Builtins.maplist(devs) do |dev|
        NetworkInterfaces.GetValue(dev, "IPADDR")
      end
      Builtins.y2milestone("ifcfgs: %1 IPs: %2", devs, ips)
      deep_copy(ips)
    end

    # if we have a static address,
    # make sure /etc/hosts resolves it to our, bnc#664929
    def ResolveHostnameToStaticIPs
      static_ips = StaticIPs()
      if Ops.greater_than(Builtins.size(static_ips), 0)
        fqhostname = Hostname.MergeFQ(DNS.hostname, DNS.domain)
        Update(fqhostname, fqhostname, static_ips)
      end

      nil
    end

    # Function which returns if the settings were modified
    # @return [Boolean]  settings were modified
    def GetModified
      @modified
    end

    # Function sets internal variable, which indicates, that any
    # settings were modified, to "true"
    def SetModified
      @modified = true

      nil
    end

    publish function: :NeedDummyIP, type: "boolean ()"
    publish function: :EnsureHostnameResolvable, type: "void ()"
    publish function: :Read, type: "boolean ()"
    publish function: :Write, type: "boolean ()"
    publish function: :Import, type: "boolean (map)"
    publish function: :Export, type: "map ()"
    publish function: :GetSystemHosts, type: "list ()"
    publish function: :Update, type: "boolean (string, string, list <string>)"
    publish function: :Summary, type: "string ()"
    publish function: :ResolveHostnameToStaticIPs, type: "void ()"
    publish function: :GetModified, type: "boolean ()"
    publish function: :SetModified, type: "void ()"

  private

    # Give address a new list of names.
    def set_names(address, names)
      @hosts.delete_by_ip(address)
      names.each do |name|
        canonical, *aliases = name.split(" ")
        @hosts.add_entry(address, canonical, aliases)
      end
      @modified = true
    end
  end

  Host = HostClass.new
  Host.main
end
