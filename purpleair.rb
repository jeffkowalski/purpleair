#!/usr/bin/env ruby
# coding: utf-8
# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'logger'
require 'rest-client'
require 'json'
require 'influxdb'

LOGFILE = File.join(Dir.home, '.log', 'purpleair.log')
SENSOR_ID = '59873'

module Kernel
  def with_rescue(exceptions, logger, retries: 5, nap: 0)
    try = 0
    begin
      yield try
    rescue *exceptions => e
      try += 1
      raise if try > retries

      logger.info "caught error #{e.class}, retrying (#{try}/#{retries})..."
      sleep nap
      retry
    end
  end
end

class PurpleAir < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new STDOUT
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end

    # from https://docs.google.com/document/d/15ijz94dXJ-YAZLi9iZ_RaBwrZ4KtYeCy08goGBwnbCU/edit
    def calc_aqi(cp0, ih0, il0, bph, bpl)
      a = (ih0 - il0)
      b = (bph - bpl)
      c = (cp0 - bpl)
      ((a / b) * c + il0).round
    end

    def aqi_from_pm(pm25)
      return -1 if pm25.nil? || pm25.nan? || pm25 > 1000
      return pm25 if pm25.negative?
      return calc_aqi(pm25, 500, 401, 500.0, 350.5) if pm25 > 350.5
      return calc_aqi(pm25, 400, 301, 350.4, 250.5) if pm25 > 250.5
      return calc_aqi(pm25, 300, 201, 250.4, 150.5) if pm25 > 150.5
      return calc_aqi(pm25, 200, 151, 150.4,  55.5) if pm25 >  55.5
      return calc_aqi(pm25, 150, 101,  55.4,  35.5) if pm25 >  35.5
      return calc_aqi(pm25, 100,  51,  35.4,  12.1) if pm25 >  12.1
      return calc_aqi(pm25,  50,   0,    12,     0) if pm25 >=    0
      -1
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  desc 'record-status', 'record the current reading to database'
  method_option :dry_run, type: :boolean, aliases: '-n', desc: "don't log to database"
  def record_status
    setup_logger

    begin
      meter = with_rescue([RestClient::TooManyRequests, RestClient::BadGateway, RestClient::GatewayTimeout, RestClient::InternalServerError, RestClient::Exceptions::OpenTimeout], @logger) do |_try|
        response = RestClient::Request.execute(
          method: 'GET',
          url: "https://www.purpleair.com/json?show=#{SENSOR_ID}"
        )
        JSON.parse response
      end
      @logger.debug meter

      influxdb = options[:dry_run] ? nil : (InfluxDB::Client.new 'purpleair')
      reading = meter['results'].first
      tags = { id: reading['ID'] }
      timestamp = reading['LastSeen'].to_i
      data = [{ series: 'pm10_0_atm', values: { value: reading['pm10_0_atm'].to_f }, tags: tags, timestamp: timestamp },
              { series: 'pm2_5_atm',  values: { value: reading['pm2_5_atm'].to_f },  tags: tags, timestamp: timestamp },
              { series: 'pm1_0_atm',  values: { value: reading['pm1_0_atm'].to_f },  tags: tags, timestamp: timestamp }]

      pm_1 = with_rescue([RestClient::TooManyRequests, RestClient::BadGateway, RestClient::GatewayTimeout, RestClient::InternalServerError, RestClient::Exceptions::OpenTimeout], @logger, nap: 6) do |_try|
        response = RestClient::Request.execute(
          method: 'GET',
          url: "https://www.purpleair.com/data.json?key=UGRT554JBQ7I7JUA&fetch=true&show=#{SENSOR_ID}&fields=pm_1"
        )
        retried = false
        begin
          @logger.debug response
          json = JSON.parse response
          # {"version":"7.0.19",
          #  "fields":
          #    ["ID","age","pm_1","conf","Type","Label","Lat","Lon","isOwner","Flags","CH"],
          #  "data":[
          #            [59873,1,90.4,100,0,"S. Peardale Dr.",37.897408,-122.14682,0,0,3]
          #          ],
          #  "count":1}
          json['data'].nil? ? json['data'] : json['data'][0][json['fields'].index('pm_1')]
        rescue JSON::ParserError => e
          @logger.warn "caught #{e.class.name} on\n#{response}"
          raise if retried

          # HACK: accommodate malformed string
          response.sub! '"data":[],', '"data":['
          response.sub!(/([^\]\n]\])(,\n"count")/, %q(\1]\2))
          @logger.warn 'retrying'
          retried = true
          retry
        end
      end

      unless pm_1.nil?
        aqi = aqi_from_pm(pm_1)
        @logger.debug "pm_1 = #{pm_1},  aqi=#{aqi_from_pm(pm_1)}"
        data.push({ series: 'aqi', values: { value: aqi }, tags: tags, timestamp: timestamp })
      end

      influxdb.write_points data unless options[:dry_run]
    rescue StandardError => e
      @logger.error e
    end
  end
end

PurpleAir.start
