#!/usr/bin/env ruby
#  encoding: UTF-8
#
# RabbitMQ check node health plugin
# ===
#
# DESCRIPTION:
# This plugin checks if RabbitMQ server node is in a running state.
#
# The plugin is based on the RabbitMQ cluster node health plugin by Tim Smith
#
# PLATFORMS:
#   Linux, Windows, BSD, Solaris
#
# DEPENDENCIES:
#   RabbitMQ rabbitmq_management plugin
#   gem: sensu-plugin
#   gem: rest-client
#
# LICENSE:
# Copyright 2012 Abhijith G <abhi@runa.com> and Runa Inc.
# Copyright 2014 Tim Smith <tim@cozy.co> and Cozy Services Ltd.
# Copyright 2015 Edward McLain <ed@edmclain.com> and Daxko, LLC.
#
# Released under the same terms as Sensu (the MIT license); see LICENSE
# for details.

require 'sensu-plugin/check/cli'
require 'json'
require 'rest_client'
require 'inifile'

# main plugin class
class CheckRabbitMQNodeHealth < Sensu::Plugin::Check::CLI
  option :host,
         description: 'RabbitMQ host',
         short: '-w',
         long: '--host HOST',
         default: 'localhost'

  option :username,
         description: 'RabbitMQ username',
         short: '-u',
         long: '--username USERNAME',
         default: 'guest'

  option :password,
         description: 'RabbitMQ password',
         short: '-p',
         long: '--password PASSWORD',
         default: 'guest'

  option :port,
         description: 'RabbitMQ API port',
         short: '-P',
         long: '--port PORT',
         default: '15672'

  option :ssl,
         description: 'Enable SSL for connection to the API',
         long: '--ssl',
         boolean: true,
         default: false

  option :verify_ssl_off,
         description: 'Do not check validity of SSL cert. Use for self-signed certs, etc (insecure)',
         long: '--verify_ssl_off',
         boolean: true,
         default: false

  option :memwarn,
         description: 'Warning % of mem usage vs high watermark',
         short: '-m',
         long: '--mwarn PERCENT',
         proc: proc(&:to_f),
         default: 80

  option :memcrit,
         description: 'Critical % of mem usage vs high watermark',
         short: '-c',
         long: '--mcrit PERCENT',
         proc: proc(&:to_f),
         default: 90

  option :fdwarn,
         description: 'Warning % of file descriptor usage vs high watermark',
         short: '-f',
         long: '--fwarn PERCENT',
         proc: proc(&:to_f),
         default: 80

  option :fdcrit,
         description: 'Critical % of file descriptor usage vs high watermark',
         short: '-F',
         long: '--fcrit PERCENT',
         proc: proc(&:to_f),
         default: 90

  option :socketwarn,
         description: 'Warning % of socket usage vs high watermark',
         short: '-s',
         long: '--swarn PERCENT',
         proc: proc(&:to_f),
         default: 80

  option :socketcrit,
         description: 'Critical % of socket usage vs high watermark',
         short: '-S',
         long: '--scrit PERCENT',
         proc: proc(&:to_f),
         default: 90

  option :watchalarms,
         description: 'Sound critical if one or more alarms are triggered',
         short: '-a BOOLEAN',
         long: '--alarms BOOLEAN',
         default: 'true'

  option :ini,
         description: 'Configuration ini file',
         short: '-i',
         long: '--ini VALUE'

  def run
    res = node_healthy?

    if res['status'] == 'ok'
      ok res['message']
    elsif res['status'] == 'warning'
      warning res['message']
    elsif res['status'] == 'critical'
      critical res['message']
    else
      unknown res['message']
    end
  end

  def _get_state(status, new)
    if status == 'ok'
      return new
    elsif status == 'warning' and new == 'critical'
      return new
    else
      return status
    end
  end

  def node_healthy?
    host       = config[:host]
    port       = config[:port]
    username   = config[:username]
    password   = config[:password]
    ssl        = config[:ssl]
    verify_ssl = config[:verify_ssl_off]
    if config[:ini]
      ini = IniFile.load(config[:ini])
      section = ini['auth']
      username = section['username']
      password = section['password']
    else
      username = config[:username]
      password = config[:password]
    end

    begin
      url_prefix = ssl ? 'https' : 'http'
      resource = RestClient::Resource.new(
        "#{url_prefix}://#{host}:#{port}/api/nodes/rabbit@#{host}",
        user: username,
        password: password,
        verify_ssl: !verify_ssl
      )
      # Parse our json data
      nodeinfo = JSON.parse(resource.get)

      # Determine % memory consumed
      pmem = format('%.2f', nodeinfo['mem_used'].fdiv(nodeinfo['mem_limit']) * 100)
      # Determine % sockets consumed
      psocket = format('%.2f', nodeinfo['sockets_used'].fdiv(nodeinfo['sockets_total']) * 100)
      # Determine % file descriptors consumed
      # Non-numeric value fd_used = 'unknown' on OSX
      if nodeinfo['fd_used'].is_a?(Numeric)
        pfd = format('%.2f', nodeinfo['fd_used'].fdiv(nodeinfo['fd_total']) * 100)
      end

      # build status and message
      status = 'ok'
      message = ''

      if pmem.to_f >= config[:memcrit]
        message += "Memory usage is critical: #{pmem}%;"
        status = _get_state(status, 'critical')
      elsif pmem.to_f >= config[:memwarn]
        message += "Memory usage is at warning: #{pmem}%;"
        status = _get_state(status, 'warning')
      end

      if psocket.to_f >= config[:socketcrit]
        message += "Socket usage is critical: #{psocket}%;"
        status = _get_state(status, 'critical')
      elsif psocket.to_f >= config[:socketwarn]
        message += "Socket usage is at warning: #{psocket}%;"
        status = _get_state(status, 'warning')
      end

      # Non-numeric value don't deal on OSX
      if pfd.nil?
        if pfd.to_f >= config[:fdcrit]
          message += "File Descriptor usage is critical: #{pfd}%;"
          status = _get_state(status, 'critical')
        elsif pfd.to_f >= config[:fdwarn]
          message += "File Descriptor usage is at warning: #{pfd}%;"
          status = _get_state(status, 'warning')
        end
      end

      # If we are set to watch alarms then watch those and set status and messages accordingly
      if config[:watchalarms] == 'true'
        if nodeinfo['mem_alarm'] == true
          status = _get_state(status, 'critical')
          message += ' Memory Alarm ON'
        end

        if nodeinfo['disk_free_alarm'] == true
          status = _get_state(status, 'critical')
          message += ' Disk Alarm ON'
        end
      end
      message = 'Server is healthy.' if status == 'ok'

      { 'status' => status, 'message' => message }
    rescue Errno::ECONNREFUSED => e
      { 'status' => 'critical', 'message' => e.message }
    rescue => e
      { 'status' => 'unknown', 'message' => e.message }
    end
  end
end
