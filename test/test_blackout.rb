#!/usr/bin/env ruby
# frozen_string_literal: true

# Тести для blackout.1m.rb
#
# Два рівні:
#   1. Чисті функції — витягуються з вихідника і перевіряються напряму
#   2. Інтеграційні — скрипт запускається процесом із тимчасовим HOME
#      і підготованим кешем, тож у мережу не ходить
#
# Запуск: ruby test/test_blackout.rb

require 'minitest/autorun'
require 'date'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'

PLUGIN = File.expand_path('../plugin/blackout.1m.rb', __dir__)
SOURCE = File.read(PLUGIN)

# Витягуємо чисті функції без запуску скрипта
module Pure
  # Константи, на які вони спираються
  %w[HOUR_VALUES].each do |const|
    body = SOURCE[/^#{const}\s*=.*?freeze$/m]
    raise "не знайдено константу #{const}" unless body

    module_eval(body)
  end

  %w[safe valid_schedule? hours_for segments minutes_until_change fmt
     siren_prefix as_schedule].each do |name|
    body = SOURCE[/^def #{Regexp.escape(name)}.*?\n^end$/m]
    raise "не знайдено метод #{name}" unless body

    module_eval(body)
    module_function name.to_sym
  end
end

# ── Чисті функції ────────────────────────────────────────────────────

class TestSafe < Minitest::Test
  def test_вирізає_роздільник_параметрів
    # SwiftBar читає '|' як початок параметрів, а bash= виконує команди
    refute_includes Pure.safe('Район | bash=/bin/sh'), '|'
  end

  def test_не_псує_звичайний_текст
    assert_equal 'Черкаський район, Уманський район',
                 Pure.safe('Черкаський район, Уманський район')
  end

  def test_обрізає_пробіли
    assert_equal 'текст', Pure.safe('  текст  ')
  end

  def test_приймає_nil
    assert_equal '', Pure.safe(nil)
  end
end

class TestValidSchedule < Minitest::Test
  def valid_doc(groups)
    { 'fact' => { 'data' => { '1791406800' => groups }, 'today' => 1_791_406_800 } }
  end

  def test_приймає_коректні_дані
    assert Pure.valid_schedule?(valid_doc('GPV1.1' => { '1' => 'yes', '2' => 'no' }))
  end

  def test_приймає_значення_first_і_second
    assert Pure.valid_schedule?(valid_doc('GPV1.1' => { '1' => 'first', '2' => 'second' }))
  end

  def test_приймає_київські_номери_черг
    assert Pure.valid_schedule?(valid_doc('GPV60.1' => { '1' => 'yes' }))
  end

  def test_відхиляє_чужі_значення_годин
    refute Pure.valid_schedule?(valid_doc('GPV1.1' => { '1' => '<script>' }))
  end

  def test_відхиляє_інєкцію_в_назві_черги
    refute Pure.valid_schedule?(valid_doc('GPV1.1 | bash=sh' => { '1' => 'yes' }))
  end

  def test_відхиляє_години_поза_діапазоном
    refute Pure.valid_schedule?(valid_doc('GPV1.1' => { '99' => 'yes' }))
    refute Pure.valid_schedule?(valid_doc('GPV1.1' => { '0' => 'yes' }))
  end

  def test_відхиляє_несправжню_дату
    doc = { 'fact' => { 'data' => { 'не-дата' => { 'GPV1.1' => { '1' => 'yes' } } } } }
    refute Pure.valid_schedule?(doc)
  end

  def test_відхиляє_не_обєкт
    refute Pure.valid_schedule?({ 'fact' => { 'data' => 'сміття' } })
    refute Pure.valid_schedule?('зовсім не те')
  end

  def test_приймає_порожні_дані
    # Дніпро й Одеса віддають порожній масив, коли відключень немає
    assert Pure.valid_schedule?({ 'fact' => { 'data' => [] } })
    assert Pure.valid_schedule?({ 'fact' => {} })
  end
end

class TestHoursFor < Minitest::Test
  def doc(hours)
    { 'fact' => { 'data' => { 'd' => { 'GPV1.1' => hours } } } }
  end

  def test_година_n_це_інтервал_n_мінус_один
    # ключ "22" у джерелі означає 21:00–22:00
    h = Pure.hours_for(doc((1..24).to_h { |i| [i.to_s, i == 22 ? 'no' : 'yes'] }), 'GPV1.1', 'd')
    refute h[21], 'індекс 21 має бути без світла'
    assert h[20]
    assert h[22]
  end

  def test_first_рахується_як_без_світла
    h = Pure.hours_for(doc('1' => 'first'), 'GPV1.1', 'd')
    refute h[0]
  end

  def test_невідома_черга
    assert_nil Pure.hours_for(doc('1' => 'yes'), 'GPV9.9', 'd')
  end
end

class TestSegments < Minitest::Test
  def test_групує_однакові_години
    hours = ([true] * 3) + ([false] * 2) + ([true] * 19)
    assert_equal [[0, 3, true], [3, 5, false], [5, 24, true]], Pure.segments(hours)
  end

  def test_весь_день_один_відрізок
    assert_equal [[0, 24, true]], Pure.segments([true] * 24)
  end
end

class TestMinutesUntilChange < Minitest::Test
  def at(hour, min)
    Time.new(2026, 10, 8, hour, min)
  end

  def test_рахує_до_зміни_сьогодні
    today = ([true] * 16) + ([false] * 8)
    assert_equal 120, Pure.minutes_until_change(today, nil, at(14, 0))
  end

  def test_переходить_на_завтра
    today = [true] * 24
    tomorrow = [false] * 24
    assert_equal 60, Pure.minutes_until_change(today, tomorrow, at(23, 0))
  end

  def test_нема_змін_взагалі
    assert_nil Pure.minutes_until_change([true] * 24, [true] * 24, at(12, 0))
  end
end

class TestSirenPrefix < Minitest::Test
  def test_жовтий_це_дрони
    assert_equal '🟡 ', Pure.siren_prefix({ level: 'yellow' })
  end

  def test_червоний_це_ракети
    assert_equal '🔴 ', Pure.siren_prefix({ level: 'red' })
  end

  def test_невідомий_рівень_вважається_червоним
    # Документація alerts.in.ua: де рівня немає, тривога трактується як червона
    assert_equal '🔴 ', Pure.siren_prefix({ level: nil })
  end

  def test_без_тривоги_нічого
    assert_equal '', Pure.siren_prefix(nil)
  end
end

class TestFmt < Minitest::Test
  def test_формат_годин_і_хвилин
    assert_equal '2:05', Pure.fmt(125)
    assert_equal '0:07', Pure.fmt(7)
    assert_equal '12:00', Pure.fmt(720)
  end
end

# ── Інтеграційні ─────────────────────────────────────────────────────

class TestIntegration < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-test')
    FileUtils.mkdir_p(File.join(@home, '.cache', 'blackout'))
    FileUtils.mkdir_p(File.join(@home, '.config'))
    # Порожній масив = alerts.energy даних не має, працює запасне джерело
    File.write(File.join(@home, '.cache', 'blackout', 'sd-cherkaska-oblast.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'sd-kyiv.json'), '[]')
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def write_cache(name, doc)
    File.write(File.join(@home, '.cache', 'blackout', "#{name}.json"), JSON.generate(doc))
  end

  # Рівень обмежень по областях. Без цього тести лізуть у мережу.
  def write_notice(title = nil)
    write_cache('notice', title ? { 'breaking' => { 'title' => title, 'excerpt' => 'текст',
                                                    'slug' => 's', 'dateSlug' => '2026-10-14' } } : {})
  end

  def write_energy(level = 2)
    write_cache('energy', [{ 'name' => 'Черкаська область', 'slug' => 'cherkaska-oblast',
                             'level' => level, 'label' => level >= 3 ? 'Аварійні відключення' : 'Погодинні графіки відключень',
                             'updated' => Time.now.iso8601 }])
  end

  def schedule(day_offset: 0, hours: nil)
    day = Date.today + day_offset
    ts = Time.new(day.year, day.month, day.day).to_i
    hours ||= (1..24).to_h { |i| [i.to_s, 'yes'] }
    { 'regionId' => 'test', 'lastUpdated' => Time.now.iso8601,
      'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => hours } },
                  'update' => '08.10.2026 21:24', 'today' => ts } }
  end

  def run_plugin(env = {})
    base = { 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
             'BLACKOUT_QUEUE' => 'GPV1.1' }
    out, err, st = Open3.capture3(base.merge(env), 'ruby', PLUGIN)
    [out, err, st]
  end

  def test_показує_графік_із_кешу_без_мережі
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, err, st = run_plugin
    assert_equal 0, st.exitstatus
    assert_empty err
    assert_match(/💡/, out)
  end

  def test_застарілі_дані_позначаються
    write_cache('Cherkasyoblenergo', schedule(day_offset: -90))
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, = run_plugin
    assert_match(/📅/, out.lines.first)
    assert_match(/застаріл/i, out)
  end

  def test_вчорашній_графік_це_невідомість_а_не_застарілість
    write_cache('Cherkasyoblenergo', schedule(day_offset: -1))
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, = run_plugin
    assert_match(/❔/, out.lines.first)
    assert_match(/на сьогодні немає/, out)
  end

  def test_невідомий_регіон_відкочується_на_типовий
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, _, st = run_plugin('BLACKOUT_REGION' => '../../etc/passwd')
    assert_equal 0, st.exitstatus
    assert_match(/Черкаська/, out)
  end

  def test_інєкція_через_чергу_не_проходить
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, = run_plugin('BLACKOUT_QUEUE' => 'GPV1.1 | bash=/bin/sh')
    refute_match(%r{bash=/bin/sh}, out)
  end

  def test_назва_району_з_мережі_санітизується
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', {
                  'states' => {
                    'Черкаська область' => {
                      'enabled' => false, 'alert_level' => nil,
                      'districts' => {
                        'Злий | bash=/bin/sh' => {
                          'enabled' => true, 'alert_level' => 'red',
                          'enabled_at' => Time.now.iso8601
                        }
                      }
                    }
                  }
                })
    out, = run_plugin
    line = out.lines.find { |l| l.start_with?('Райони:') }
    refute_nil line, 'рядок з районами має бути'

    # SwiftBar ділить текст і параметри на ПЕРШОМУ '|'.
    # Якщо санітизація спрацювала, bash= лишиться в тексті, а не стане параметром.
    _title, params = line.split('|', 2)
    refute_includes params.to_s, 'bash=',
                    'назва району з мережі не має ставати параметром меню'
    assert_match(/Тривога/, out)
  end

  def test_пошкоджений_кеш_не_кладе_скрипт
    File.write(File.join(@home, '.cache', 'blackout', 'Cherkasyoblenergo.json'), '{зламано')
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    _, err, st = run_plugin
    assert_equal 0, st.exitstatus
    assert_empty err
  end

  def test_зіпсована_дата_тривоги_не_кладе_скрипт
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', {
                  'states' => {
                    'Черкаська область' => {
                      'enabled' => true, 'alert_level' => 'yellow',
                      'enabled_at' => 'зовсім-не-дата', 'districts' => {}
                    }
                  }
                })
    out, err, st = run_plugin
    assert_equal 0, st.exitstatus
    assert_empty err
    assert_match(/Тривога/, out)
  end

  def test_тривога_лише_по_районах_помічається
    # Прапорець області лишається false, горять тільки райони
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', {
                  'states' => {
                    'Черкаська область' => {
                      'enabled' => false, 'alert_level' => nil,
                      'districts' => {
                        'Уманський район' => { 'enabled' => true, 'alert_level' => 'red',
                                               'enabled_at' => Time.now.iso8601 }
                      }
                    }
                  }
                })
    out, = run_plugin
    assert_match(/🔴/, out.lines.first)
    assert_match(/Уманський район/, out)
  end

  def test_перемикач_не_приймає_чужий_регіон
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    Open3.capture3({ 'HOME' => @home }, 'ruby', PLUGIN, '--set', 'зловмисний', 'GPV1.1')
    cfg = File.join(@home, '.config', 'blackout.json')
    refute File.exist?(cfg), 'конфіг не мав створитись'
  end

  def test_перемикач_приймає_відомий_регіон
    write_cache('kyiv', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    Open3.capture3({ 'HOME' => @home }, 'ruby', PLUGIN, '--set', 'kyiv', 'GPV5.1')
    cfg = JSON.parse(File.read(File.join(@home, '.config', 'blackout.json')))
    assert_equal 'kyiv', cfg['region']
    assert_equal 'GPV5.1', cfg['queue']
  end

  def test_попередження_обмежене_діапазоном
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    Open3.capture3({ 'HOME' => @home }, 'ruby', PLUGIN, '--warn', '999999')
    cfg = JSON.parse(File.read(File.join(@home, '.config', 'blackout.json')))
    assert_equal 720, cfg['warn_minutes']
  end

  def test_у_виводі_немає_селекторів_варіації
    # U+FE0F малюється квадратиком у шрифті menu bar
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, = run_plugin
    refute_includes out.lines.first, '️',
                    'перший рядок не має містити U+FE0F'
  end
end

class TestHourValues < Minitest::Test
  def doc(value)
    { 'fact' => { 'data' => { '1791406800' => { 'GPV1.1' => { '1' => value } } } } }
  end

  def test_приймає_всі_документовані_значення
    # preset.time_type у джерелі: yes, no, first, second, maybe, mfirst, msecond
    %w[yes no first second maybe mfirst msecond].each do |v|
      assert Pure.valid_schedule?(doc(v)), "значення #{v} має прийматись"
    end
  end

  def test_відхиляє_недокументоване
    refute Pure.valid_schedule?(doc('<script>'))
    refute Pure.valid_schedule?(doc('possibly'))
  end

  def test_світло_лише_при_yes
    # Часткові й імовірні відключення трактуємо як «світла не буде»
    %w[no first second maybe mfirst msecond].each do |v|
      h = Pure.hours_for({ 'fact' => { 'data' => { 'd' => { 'GPV1.1' => { '1' => v } } } } },
                         'GPV1.1', 'd')
      refute h[0], "значення #{v} не має рахуватись як світло"
    end
  end
end

class TestEmergency < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-emergency')
    FileUtils.mkdir_p(File.join(@home, '.cache', 'blackout'))
    FileUtils.mkdir_p(File.join(@home, '.config'))
    # Порожній масив = alerts.energy даних не має, працює запасне джерело
    File.write(File.join(@home, '.cache', 'blackout', 'sd-cherkaska-oblast.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'sd-kyiv.json'), '[]')
    day = Date.today
    ts = Time.new(day.year, day.month, day.day).to_i
    write('Cherkasyoblenergo',
          'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } } },
                      'today' => ts })
    write('alerts', 'states' => {})
    write('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def write(name, doc)
    File.write(File.join(@home, '.cache', 'blackout', "#{name}.json"), JSON.generate(doc))
  end

  def energy(level, label)
    write('energy', [{ 'name' => 'Черкаська область', 'level' => level, 'label' => label }])
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_рівень_3_це_аварійні
    energy(3, 'Аварійні відключення')
    out = run_plugin
    assert_match(/🚨/, out.lines.first)
    assert_match(/Графік не діє/, out)
  end

  def test_під_час_аварійних_відлік_не_показується
    # Графік не діє, тож показувати за ним час до зміни було б брехнею
    energy(3, 'Аварійні відключення')
    assert_equal '🚨', run_plugin.lines.first.strip
  end

  def test_рівень_2_це_звичайний_графік
    energy(2, 'Погодинні графіки відключень')
    out = run_plugin
    refute_match(/🚨/, out.lines.first)
    assert_match(/💡/, out.lines.first)
  end

  def test_невідома_область_не_ламає
    write('energy', [{ 'name' => 'Марсіанська область', 'level' => 3, 'label' => 'Аварійні' }])
    out, err, st = Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                                    'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN)
    assert_equal 0, st.exitstatus
    assert_empty err
    refute_match(/🚨/, out.lines.first)
  end

  def test_мітка_з_мережі_санітизується
    energy(3, 'Аварійні | bash=/bin/sh')
    line = run_plugin.lines.find { |l| l.include?('Аварійні') }
    _title, params = line.split('|', 2)
    refute_includes params.to_s, 'bash='
  end
end

class TestDaySelection < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-day')
    FileUtils.mkdir_p(File.join(@home, '.cache', 'blackout'))
    FileUtils.mkdir_p(File.join(@home, '.config'))
    # Порожній масив = alerts.energy даних не має, працює запасне джерело
    File.write(File.join(@home, '.cache', 'blackout', 'sd-cherkaska-oblast.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'sd-kyiv.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'alerts.json'), '{"states":{}}')
    File.write(File.join(@home, '.cache', 'blackout', 'energy.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'notice.json'), '{}')
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def ts(offset)
    d = Date.today + offset
    Time.new(d.year, d.month, d.day).to_i
  end

  def test_бере_сьогоднішній_день_навіть_коли_поле_today_відстає
    # Опівночі джерело ще віддає вчорашнє fact.today, хоча сьогоднішній
    # графік у файлі вже є. Старий код показував би ❔
    doc = { 'fact' => {
      'data' => {
        ts(-1).to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'no'] } },
        ts(0).to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } }
      },
      'today' => ts(-1)
    } }
    File.write(File.join(@home, '.cache', 'blackout', 'Cherkasyoblenergo.json'),
               JSON.generate(doc))
    out, = Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                            'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN)
    refute_match(/❔/, out.lines.first, 'мав взяти сьогоднішній день')
    assert_match(/💡/, out.lines.first)
    assert_match(/Сьогодні/, out)
  end
end

class TestNotice < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-notice')
    FileUtils.mkdir_p(File.join(@home, '.cache', 'blackout'))
    FileUtils.mkdir_p(File.join(@home, '.config'))
    # Порожній масив = alerts.energy даних не має, працює запасне джерело
    File.write(File.join(@home, '.cache', 'blackout', 'sd-cherkaska-oblast.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'sd-kyiv.json'), '[]')
    d = Date.today
    ts = Time.new(d.year, d.month, d.day).to_i
    w('Cherkasyoblenergo', 'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } } }, 'today' => ts })
    w('alerts', 'states' => {})
    w('energy', [])
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@home, '.cache', 'blackout', "#{name}.json"), JSON.generate(doc))
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_показує_новину
    w('notice', 'breaking' => { 'title' => 'Обмеження 16:00-22:00', 'excerpt' => 'Через атаку',
                                'slug' => 'obmezhennia', 'dateSlug' => '2026-10-14' })
    out = run_plugin
    assert_match(/📰 Обмеження 16:00-22:00/, out)
    assert_match(%r{href=https://alerts.energy/news/2026-10-14/obmezhennia}, out)
  end

  def test_без_новини_нічого_не_показує
    w('notice', {})
    refute_match(/📰/, run_plugin)
  end

  def test_новина_з_мережі_санітизується
    w('notice', 'breaking' => { 'title' => 'Атака | bash=/bin/sh', 'excerpt' => '' })
    line = run_plugin.lines.find { |l| l.include?('📰') }
    _title, params = line.split('|', 2)
    refute_includes params.to_s, 'bash='
  end
end

class TestShutdownsSource < Minitest::Test
  def rows(extra = [])
    base = { 'initiator' => 'cherkaska_oblast_oblenergo', 'queue' => '1.1',
             'today' => (([0] * 10) + [1, 1] + ([0] * 12)),
             'todayPossible' => [0] * 24,
             'tomorrow' => [], 'todayStatus' => 'ScheduleApplies',
             'tomorrowStatus' => 'WaitingForSchedule',
             'todayDate' => Date.today.to_s,
             'todayCheckedAt' => Time.now.utc.iso8601 }
    [base] + extra
  end

  def built(rs)
    Pure.as_schedule(rs)
  end

  def test_одиниця_означає_відключення
    d = built(rows)
    ts = d['fact']['data'].keys.first
    h = d['fact']['data'][ts]['GPV1.1']
    assert_equal 'yes', h['1']   # година 0–1
    assert_equal 'no', h['11']   # година 10–11
    assert_equal 'no', h['12']
    assert_equal 'yes', h['13']
  end

  def test_обирає_обленерго_а_не_залізницю
    # На одну чергу буває кілька постачальників із різними графіками
    uz = { 'initiator' => 'cherkaska_oblast_uz', 'queue' => '1.1',
           'today' => (([0] * 15) + [1, 1] + ([0] * 7)), 'todayPossible' => [0] * 24,
           'todayStatus' => 'ScheduleApplies', 'todayDate' => Date.today.to_s }
    d = built(rows([uz]))
    h = d['fact']['data'].values.first['GPV1.1']
    assert_equal 'no', h['11'], 'має бути графік обленерго'
    assert_equal 'yes', h['16'], 'не має бути графік залізниці'
  end

  def test_possible_стає_maybe
    rs = rows
    rs[0]['todayPossible'] = ([0] * 5) + [1] + ([0] * 18)
    h = built(rs)['fact']['data'].values.first['GPV1.1']
    assert_equal 'maybe', h['6']
  end

  def test_noshutdowns_це_світло_весь_день
    rs = [{ 'initiator' => 'x_oblenergo', 'queue' => '1.1', 'today' => [],
            'todayStatus' => 'NoShutdowns', 'todayDate' => Date.today.to_s }]
    h = built(rs)['fact']['data'].values.first['GPV1.1']
    assert_equal 24, h.values.count('yes')
  end

  def test_порожні_рядки_дають_nil
    assert_nil built([])
  end

  def test_результат_проходить_валідацію
    assert Pure.valid_schedule?(built(rows))
  end
end

class TestParamInjection < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-param')
    c = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(c)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    d = Date.today
    ts = Time.new(d.year, d.month, d.day).to_i
    File.write(File.join(c, 'sd-cherkaska-oblast.json'), '[]')
    File.write(File.join(c, 'Cherkasyoblenergo.json'), JSON.generate(
                 'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } } }, 'today' => ts }))
    File.write(File.join(c, 'alerts.json'), '{"states":{}}')
    File.write(File.join(c, 'energy.json'), '[]')
    @cache = c
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  # Параметри SwiftBar розділяються ПРОБІЛАМИ, тож safe() тут не досить:
  # вона вирізає лише '|'. Значення з мережі мають або проходити
  # сувору перевірку, або не виводитись узагалі.
  def test_slug_новини_не_може_підсунути_параметр
    File.write(File.join(@cache, 'notice.json'), JSON.generate(
                 'breaking' => { 'title' => 'Новина', 'excerpt' => 'т', 'dateSlug' => '2026-10-14',
                                 'slug' => 'x terminal=true bash=/bin/sh param1=-c' }))
    out = run_plugin
    refute_match(%r{bash=/bin/sh}, out, 'slug із пробілами не має ставати параметром')
    refute_match(/Читати/, out, 'посилання з підозрілим slug не має виводитись')
    assert_match(/📰/, out, 'сама новина має лишитись')
  end

  def test_нормальний_slug_дає_посилання
    File.write(File.join(@cache, 'notice.json'), JSON.generate(
                 'breaking' => { 'title' => 'Новина', 'excerpt' => 'т', 'dateSlug' => '2026-10-14',
                                 'slug' => 'sytuatsiia-v-energosystemi' }))
    assert_match(%r{href=https://alerts.energy/news/2026-10-14/sytuatsiia-v-energosystemi},
                 run_plugin)
  end

  def test_dateslug_теж_перевіряється
    File.write(File.join(@cache, 'notice.json'), JSON.generate(
                 'breaking' => { 'title' => 'Н', 'excerpt' => 'т', 'dateSlug' => 'a bash=/bin/sh',
                                 'slug' => 'ok-slug' }))
    refute_match(%r{bash=/bin/sh}, run_plugin)
  end

  def test_шлях_зі_пробілами_береться_в_лапки
    # Якщо застосунок лежить у теці з пробілом, без лапок решта шляху
    # стане окремими параметрами SwiftBar
    line = run_plugin.lines.find { |l| l.include?('param1=--set') }
    refute_nil line
    assert_match(/bash="[^"]+"/, line, 'шлях має бути в лапках')
  end
end
