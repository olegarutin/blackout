#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>Blackout</xbar.title>
# <xbar.version>v2.0</xbar.version>
# <xbar.author>Oleg Arutin</xbar.author>
# <xbar.desc>Графік погодинних відключень: стан, відлік і сповіщення про зміни</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>

# The schedule is in Kyiv hours. On a Mac in another zone the same data
# gave the opposite answer: "no power" in Kyiv, "power on" in Lisbon.
# Pin the zone for the whole process before touching Time at all.
ENV['TZ'] = 'Europe/Kyiv'

require_relative '../lib/blackout'

# This path goes into the bash= parameter of menu items. In a directory
# with a space, an unquoted path would split into extra parameters.
SELF = File.expand_path(__FILE__)

cfg = load_config

case ARGV[0]
when '--set'
  exit unless REGIONS.key?(utf8(ARGV[1])) && utf8(ARGV[2]).to_s.match?(/\AGPV\d{1,3}\.\d{1,2}\z/)

  cfg['region'] = utf8(ARGV[1])
  cfg['queue']  = utf8(ARGV[2])
  save_config(cfg)
  exit
when '--warn'
  cfg['warn_minutes'] = ARGV[1].to_i.clamp(1, 720)
  save_config(cfg)
  exit
when '--notify'
  cfg['notify'] = (ARGV[1] == 'on')
  save_config(cfg)
  exit
when '--alerts'
  cfg['alerts'] = (ARGV[1] == 'on')
  save_config(cfg)
  exit
when '--district'
  # An empty value means the whole oblast. The district name comes from
  # a menu built out of network data, so check its shape.
  d = utf8(ARGV[1]).to_s
  exit unless d.empty? || d.match?(/\A[\p{L}\p{Zs}'’-]{3,60}\z/)

  cfg['district'] = d.empty? ? nil : d
  save_config(cfg)
  exit
end

# The region becomes part of a URL and of a cache path, so only known
# keys are accepted. The queue is matched against a strict pattern: it
# reaches the menu text, where '|' starts the parameters.
raw_region = utf8(ENV['BLACKOUT_REGION']) || cfg['region']
raw_queue  = utf8(ENV['BLACKOUT_QUEUE'])  || cfg['queue']

# Until a choice is made, showing one region as "yours" is a lie to
# everyone else. The fallbacks stay so the rest of the code has
# something to work with, but the picker outranks any schedule.
CONFIGURED = (REGIONS.key?(raw_region) &&
              raw_queue.to_s.match?(/\AGPV\d{1,3}\.\d{1,2}\z/)) ? true : false
REGION = REGIONS.key?(raw_region) ? raw_region : 'Cherkasyoblenergo'
QUEUE  = raw_queue.to_s.match?(/\AGPV\d{1,3}\.\d{1,2}\z/) ? raw_queue : 'GPV1.1'
WARN   = (cfg['warn_minutes'] || 15).to_i
NOTIFY = cfg.fetch('notify', true)
ALERTS_ON = cfg.fetch('alerts', true)
# The district name came from a menu built out of network data, so
# check its shape before trusting it
raw_district = utf8(ENV['BLACKOUT_DISTRICT']) || cfg['district']
DISTRICT = raw_district.to_s.match?(/\A[\p{L}\p{Zs}'’-]{3,60}\z/) ? raw_district : nil

render
