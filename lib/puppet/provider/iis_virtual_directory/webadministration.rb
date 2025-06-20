# frozen_string_literal: true

require File.join(File.dirname(__FILE__), '../../../puppet/provider/iis_common')
require File.join(File.dirname(__FILE__), '../../../puppet/provider/iis_powershell')

Puppet::Type.type(:iis_virtual_directory).provide(:webadministration, parent: Puppet::Provider::IIS_PowerShell) do
  desc 'IIS Virtual Directory provider using the PowerShell WebAdministration module'

  confine     feature: :pwshlib
  confine     feature: :iis_web_server
  confine     operatingsystem: [:windows]
  defaultfor  operatingsystem: :windows

  def self.powershell_path
    require 'ruby-pwsh'
    Pwsh::Manager.powershell_path
  rescue LoadError
    nil
  end

  commands powershell: powershell_path

  mk_resource_methods

  def exists?
    @property_hash[:ensure] == :present
  end

  def create
    Puppet.debug "Creating #{@resource[:name]}"

    verify_physicalpath
    dir_path = virt_dir_path

    cmd = []
    if local_path?(@resource[:physicalpath])
      cmd << "New-WebVirtualDirectory -Name \"#{@resource[:name]}\" "
      raise('sitename is a required parameter') unless @resource[:sitename]

      cmd << "-Site \"#{@resource[:sitename]}\" "
    else
      # New-WebVirtualDirectory fails when PhysicalPath is a UNC path that unavailable,
      # and UNC paths are inherently not necessarily always available.
      cmd << "New-Item -Type VirtualDirectory 'IIS:\\Sites\\#{dir_path}' "
    end
    cmd << "-Application \"#{@resource[:application]}\" " if @resource[:application]
    cmd << "-PhysicalPath \"#{@resource[:physicalpath]}\" " if @resource[:physicalpath]
    cmd << '-ErrorAction Stop;'
    if @resource[:user_name]
      cmd << "Set-ItemProperty -Path 'IIS:\\Sites\\#{dir_path}' " \
             "-Name 'userName' -Value '#{@resource[:user_name]}' -ErrorAction Stop;"
    end
    if @resource[:password]
      cmd << "Set-ItemProperty -Path 'IIS:\\Sites\\#{dir_path}' " \
             "-Name 'password' -Value '#{escape_string(@resource[:password])}' -ErrorAction Stop;"
    end
    cmd = cmd.join

    result = self.class.run(cmd)
    Puppet.err "Error creating virtual directory: #{result[:errormessage]}" unless (result[:exitcode]).zero?
    @resource[:ensure] = :present
  end

  def update
    Puppet.debug "Updating #{@resource[:name]}"

    verify_physicalpath

    cmd = []

    cmd << "Set-ItemProperty -Path 'IIS:\\Sites\\#{virt_dir_path}' -Name 'physicalPath' -Value '#{@resource[:physicalpath]}';" if @resource[:physicalpath]
    cmd << "Set-ItemProperty -Path 'IIS:\\Sites\\#{virt_dir_path}' -Name 'application' -Value '#{@resource[:application]}';" if @resource[:application]
    cmd << "Set-ItemProperty -Path 'IIS:\\Sites\\#{virt_dir_path}' -Name 'userName' -Value '#{@resource[:user_name]}';" if @resource[:user_name]
    cmd << "Set-ItemProperty -Path 'IIS:\\Sites\\#{virt_dir_path}' -Name 'password' -Value '#{escape_string(@resource[:password])}';" if @resource[:password]

    cmd = cmd.join
    result = self.class.run(cmd)
    Puppet.err "Error updating virtual directory: #{result[:errormessage]}" unless (result[:exitcode]).zero?
  end

  def destroy
    Puppet.debug "Destroying #{@resource[:name]}"
    test = self.class.run("Test-Path -Path 'IIS:\\Sites\\#{virt_dir_path}'")
    if test[:stdout].strip.casecmp('true').zero?
      cmd = []
      cmd << 'Remove-Item '
      cmd << "-Path 'IIS:\\Sites\\#{virt_dir_path}' "
      cmd << '-Recurse '
      cmd << '-ErrorAction Stop '
      cmd = cmd.join

      result = self.class.run(cmd)
      Puppet.err "Error destroying virtual directory: #{result[:errormessage]}" unless (result[:exitcode]).zero?
    end
    @property_hash[:ensure] = :absent
  end

  def initialize(value = {})
    super(value)
    @property_flush = {}
  end

  def self.prefetch(resources)
    virt_dirs = instances
    resources.each_key do |virt_dir|
      if (provider = virt_dirs.find { |s| virt_dir.casecmp(s.name).zero? })
        resources[virt_dir].provider = provider
      end
    end
  end

  def self.instances
    cmd = ps_script_content('_getvirtualdirectories', @resource)
    result = run(cmd)
    return [] if result.nil?

    virt_dir_json = parse_json_result(result[:stdout])
    return [] if virt_dir_json.nil?

    virt_dir_json.map do |virt_dir|
      virt_dir_hash = {}

      virt_dir_hash[:ensure]       = :present
      virt_dir_hash[:name]         = virt_dir['name']
      virt_dir_hash[:physicalpath] = virt_dir['physicalpath']
      virt_dir_hash[:user_name]    = virt_dir['user_name']
      virt_dir_hash[:password]     = virt_dir['password']
      virt_dir_hash[:application]  = virt_dir['application']
      virt_dir_hash[:sitename]     = virt_dir['sitename']

      new(virt_dir_hash)
    end
  end

  def virt_dir_path
    sitename = @resource[:sitename]
    name = @resource[:name]
    app_name = @resource[:application] if @resource[:application]

    @cached_virt_dir_path ||= {}

    cache_key = "#{sitename}/#{name}/#{app_name}"
    @cached_virt_dir_path[cache_key] ||= begin
      parts = name.tr('/', '\\').split('\\')
      parts.shift if parts.first&.casecmp?(sitename)
      parts.shift if app_name && parts.first&.casecmp?(app_name)

      path_parts = [sitename]
      path_parts << app_name if app_name
      path_parts.concat(parts)

      path_parts.join('\\')
    end
  end

  def escape_string(value)
    value.gsub("'", "''")
  end
end
