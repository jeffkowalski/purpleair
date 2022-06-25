#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

# https://community.purpleair.com/t/making-api-calls-with-the-purpleair-api/180

class PurpleAir < RecorderBotBase
  no_commands do
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

  no_commands do
    def main
      credentials = load_credentials

      soft_faults = [
        RestClient::BadGateway,
        RestClient::Exceptions::OpenTimeout,
        RestClient::GatewayTimeout,
        RestClient::InternalServerError,
        RestClient::TooManyRequests
      ]

      influxdb = options[:dry_run] ? nil : (InfluxDB::Client.new 'purpleair')

      meter = with_rescue(soft_faults, @logger) do |_try|
        response = RestClient::Request.execute(
          method: 'GET',
          url: "https://api.purpleair.com/v1/sensors/#{credentials[:sensor_id]}",
          headers: { x_api_key: credentials[:read_key] }
        )
        JSON.parse response
      end
      @logger.debug meter

      reading = meter['sensor']
      tags = { id: reading['sensor_index'] }
      timestamp = reading['last_seen'].to_i
      aqi = aqi_from_pm(reading['stats_a']['pm2.5_10minute'].to_f)
      data = [{ series: 'pm10_0_atm', values: { value: reading['pm10.0_atm'].to_f }, tags: tags, timestamp: timestamp },
              { series: 'pm2_5_atm',  values: { value: reading['pm2.5_atm'].to_f },  tags: tags, timestamp: timestamp },
              { series: 'pm1_0_atm',  values: { value: reading['pm1.0_atm'].to_f },  tags: tags, timestamp: timestamp },
              { series: 'aqi',        values: { value: aqi },                        tags: tags, timestamp: timestamp }]
      @logger.debug data

      influxdb.write_points data unless options[:dry_run]
    end
  end
end

PurpleAir.start
