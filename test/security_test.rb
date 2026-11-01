#!/usr/bin/env ruby
# frozen_string_literal: true

# Attacks, kept as tests so they cannot come back.
#
# Everything here assumes the worst: that a source we read has been
# taken over and answers with whatever hurts most. The app may show
# wrong hours in that case — there are no signatures on this data, and
# the README says so. It may not run anything, write anywhere, or stop
# working altogether.
#
# Run: ruby test/security_test.rb

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
ENV['TZ'] = 'Europe/Kyiv'

require 'minitest/autorun'
require 'json'
require 'date'
require 'time'
require 'tmpdir'
require 'fileutils'
require 'open3'

require_relative '../lib/blackout'

PAYLOADS = [
  'X | bash=/usr/bin/touch param1=/tmp/PWNED',
  '" & do shell script "touch /tmp/PWNED" & "',
  "рядок\nпідроблений пункт | color=red",
  "NUL\u0000 escape\u001B[31m",
  '‮текст задом наперед',
  '`id`; rm -rf ~; $(whoami)',
  "\xC3\x28\xFF\xFE".dup.force_encoding('UTF-8')
].freeze

class TestTextFromASource < Minitest::Test
  def test_nothing_survives_that_could_become_a_parameter
    PAYLOADS.each do |p|
      out = safe(p)

      assert_predicate out, :valid_encoding?, p.inspect
      refute_includes out, '|', p.inspect
      refute_match(/[\u0000-\u001F\u007F​-‏‪-‮﻿]/, out, p.inspect)
      refute_includes out, "\n", p.inspect
    end
  end

  def test_length_is_capped_whatever_arrives
    assert_operator safe('я' * 500_000).length, :<=, 201
  end
end

class TestLinksFromASource < Minitest::Test
  REFUSED = ['https://evil.example/news/2026/01/01/x',
             'javascript:alert(1)',
             'file:///etc/passwd',
             'data:text/html,<script>',
             'https://alerts.energy/news/a b bash=/bin/sh',
             'https://t.me/Ukrenergo/1 terminal=true',
             'http://alerts.energy/news/2026/01/01/x',
             nil, ''].freeze

  def test_only_known_hosts_and_shapes_are_printed
    REFUSED.each { |u| assert_nil news_url(u), u.inspect }
  end

  def test_the_real_shapes_still_pass
    assert news_url('https://alerts.energy/news/2026/10/27/zahody')
    assert news_url('https://t.me/Ukrenergo/5581')
  end
end

# A slug from a source is pasted into the URL we then request.
class TestRequestAddressCannotBeMoved < Minitest::Test
  TRAVERSAL = ['../../../etc/passwd', '..%2f..%2fadmin', 'a/../../x',
               'http://169.254.169.254/latest/meta-data/', 'evil.com/x',
               'a?x=1', 'a#frag', 'a b', 'A' * 300].freeze

  def test_no_slug_escapes_its_place
    TRAVERSAL.each do |slug|
      title = "Графік погодинних відключень на #{Date.today.day} " \
              "#{MONTHS[Date.today.month - 1]}"
      items = [{ 'title' => title, 'slug' => slug,
                 'publishedAt' => Time.now.iso8601 }]

      assert_empty newest_schedule_posts(items), slug.inspect
    end
  end
end

# A regex that backtracks catastrophically turns any source into an off
# switch, and the response cap still allows two megabytes.
class TestNothingTakesTooLong < Minitest::Test
  BUDGET = 1.0

  def fast_enough?(seconds)
    started = Time.now
    yield
    Time.now - started < seconds
  end

  def test_parsers_stay_fast_on_hostile_input
    span = '12:00 - 14:00'

    assert fast_enough?(BUDGET) { parse_outage_text("1.1 #{"#{span}, " * 50_000}") }
    assert fast_enough?(BUDGET) { parse_outage_text("1.1 12:00 - 14:00\n" * 100_000) }
    assert fast_enough?(BUDGET) { safe(" \t\n" * 700_000) }
    assert fast_enough?(BUDGET) { oblasts_named("знеструмлення #{'а' * 2_000_000}", ['Сумська область']) }
    long_html = "#{'<b>' * 400_000}Графік оновлено: 01.01, 00:00"

    assert fast_enough?(BUDGET) { page_revised_at(long_html) }
    assert fast_enough?(BUDGET) { telegram_posts('<div class="tgme_widget_message">x</div>' * 5_000) }
  end
end

class TestMalformedStructures < Minitest::Test
  def test_a_nesting_bomb_is_refused
    assert_raises(JSON::NestingError) { JSON.parse(('[' * 200) + (']' * 200)) }
  end

  def test_impossible_hours_cost_their_own_line_only
    parsed = parse_outage_text("1.1 12:00 - 14:00\n9.9 00:00 - 99:99\n2.1 25:00 - 26:00\n")

    assert_equal ['1.1'], parsed.keys
  end

  def test_every_parser_shrugs_at_rubbish
    PAYLOADS.each do |p|
      assert_kind_of Hash, parse_outage_text(p)
      assert_kind_of Array, oblasts_named(p, ['Сумська область'])
      assert_kind_of Array, telegram_posts(p)
      assert_nil page_revised_at(p) if p.valid_encoding?
    end
  end
end

# Local conditions must cost their own feature, never the menu. An
# unwritable cache used to take the whole render down with it, and an
# unwritable config printed a Ruby backtrace into the menu bar.
class TestDiskTroubleIsNotFatal < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-disk')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    day = Date.today
    ts = Time.new(day.year, day.month, day.day).to_i
    hours = (1..24).to_h { |h| [h.to_s, 'yes'] }
    File.write(File.join(@cache, 'Cherkasyoblenergo.json'),
               JSON.generate('fact' => { 'data' => { ts.to_s => { 'GPV1.1' => hours } },
                                         'update' => Time.now.strftime('%d.%m.%Y %H:%M'),
                                         'today' => ts }))
    File.write(File.join(@cache, 'alerts.json'), '{"states":{}}')
    %w[t.me_s alerts.energy_api alerts.energy_cherkaska-oblast
       raw.githubusercontent.com_yaroslav2901 www.cherkasyoblenergo.com_api
       vadimklimenko.com_map].each { |k| FileUtils.touch(File.join(@cache, "deny-#{k}")) }
  end

  def teardown
    FileUtils.chmod(0o700, @cache)
    FileUtils.chmod(0o700, File.join(@home, '.config'))
    FileUtils.remove_entry(@home)
  end

  def run_plugin(*args)
    plugin = File.expand_path('../plugin/blackout.1m.rb', __dir__)
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', plugin, *args)
  end

  def test_a_read_only_cache_still_shows_the_schedule
    FileUtils.chmod(0o500, @cache)
    out, = run_plugin

    assert_match(/Світло є/, out)
    refute_match(/Несподівана помилка/, out)
  end

  def test_a_read_only_config_says_so_in_one_line
    FileUtils.chmod(0o500, File.join(@home, '.config'))
    out, err = run_plugin('--warn', '30')

    assert_match(/Не вдалося зберегти/, out)
    refute_match(/blackout.*\.rb:\d+/, out + err, 'a backtrace must not reach the menu')
  end

  def test_no_variation_selectors_in_that_message
    FileUtils.chmod(0o500, File.join(@home, '.config'))
    out, = run_plugin('--warn', '30')

    refute_includes out, "\uFE0F", 'U+FE0F draws as a tofu box'
  end
end
