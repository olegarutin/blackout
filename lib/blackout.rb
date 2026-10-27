# frozen_string_literal: true

# Blackout — Ukrainian power-outage schedule and air-raid alerts for the
# macOS menu bar. This file wires the parts together; the executable the
# menu-bar host runs is plugin/blackout.1m.rb.
#
# Load order matters: sources defines the URLs that regions points at,
# and store defines the cache paths the fetchers write to.

require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'digest'
require 'date'
require 'time'

# Without locale variables Ruby reads files as US-ASCII and Cyrillic
# breaks parsing. default_external only: default_internal would make
# Ruby transcode on write, and Net::HTTP hands back a binary body, so
# the write would raise and leave an empty cache file behind.
Encoding.default_external = Encoding::UTF_8

require_relative 'blackout/sources'
require_relative 'blackout/regions'
require_relative 'blackout/util'
require_relative 'blackout/store'
require_relative 'blackout/http'
require_relative 'blackout/schedule'
require_relative 'blackout/fetch'
require_relative 'blackout/grid'
require_relative 'blackout/alerts'
require_relative 'blackout/menu'
require_relative 'blackout/render'
