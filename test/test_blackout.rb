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

# Без змінних локалі Ruby читає файли й вивід підпроцесів як US-ASCII,
# і кирилиця ламає порівняння. Фіксуємо явно.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require 'minitest/autorun'
require 'date'
require 'time'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'

PLUGIN = File.expand_path('../plugin/blackout.1m.rb', __dir__)
SOURCE = File.read(PLUGIN, encoding: 'UTF-8')

# Витягуємо чисті функції без запуску скрипта
module Pure
  # Константи, на які вони спираються
  %w[HOUR_VALUES].each do |const|
    body = SOURCE[/^#{const}\s*=.*?freeze$/m]
    raise "не знайдено константу #{const}" unless body

    module_eval(body)
  end

  %w[safe valid_schedule? hours_for segments minutes_until_change fmt
     siren_prefix as_schedule fmt_updated read_etag read_cache
     atomic_write touch_cache ensure_dir read_schedule valid_rows?].each do |name|
    body = SOURCE[/^def #{Regexp.escape(name)}(?![\w?!]).*?\n^end$/m]
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

  # Назва черги з кешу йде у значення param3 пункту меню. Доки схема
  # перевірялась лише на записі, підмінений кеш міг додати власний bash=.
  def test_отруєна_назва_черги_з_кешу_не_йде_в_параметри
    day = Date.today
    ts = Time.new(day.year, day.month, day.day).to_i
    hours = (1..24).to_h { |i| [i.to_s, 'yes'] }
    poison = 'GPV9.9 bash=/usr/bin/touch param1=/tmp/BLACKOUT_PWNED'
    write_cache('Cherkasyoblenergo',
                'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => hours, poison => hours } },
                            'today' => ts })
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })

    out = run_plugin.first
    refute_match(/BLACKOUT_PWNED/, out, 'отруєна назва черги потрапила у вивід')
    out.each_line do |line|
      params = line.split('|', 2)[1]
      next unless params

      assert_operator params.scan(/(?:\A|\s)bash=/).size, :<=, 1,
                       "два bash= в одному пункті: #{line}"
    end
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

class TestFmtUpdated < Minitest::Test
  def test_iso_стає_місцевим_часом
    # alerts.energy віддає UTC в ISO — показувати його сирим негарно
    out = Pure.fmt_updated('2026-10-14T17:54:18.249Z')
    assert_match(/\A\d{2}\.\d{2} \d{2}:\d{2}\z/, out)
    refute_match(/T|Z/, out)
  end

  def test_готовий_рядок_не_чіпається
    # GitHub-репозиторії віддають уже відформатований час
    assert_equal '14.10.2026 20:54', Pure.fmt_updated('14.10.2026 20:54')
  end

  def test_сміття_не_ламає
    assert_equal 'хтозна', Pure.fmt_updated('хтозна')
    assert_equal '', Pure.fmt_updated(nil)
  end
end

class TestCacheIntegrity < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-cache')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  # Якщо кеш зіпсований, а ETag валідний, сервер відповідатиме 304
  # на порожній файл — і дані вже ніколи не завантажаться.
  def test_зіпсований_кеш_скидає_etag
    path = File.join(@cache, 'alerts.json')
    File.write(path, '')
    File.write("#{path}.etag", 'W/"abc123"')
    assert_nil Pure.read_etag(path), 'ETag не має віддаватись для нечитабельного кешу'
  end

  def test_справний_кеш_віддає_etag
    path = File.join(@cache, 'alerts.json')
    File.write(path, '{"states":{}}')
    File.write("#{path}.etag", 'W/"abc123"')
    assert_equal 'W/"abc123"', Pure.read_etag(path)
  end

  def test_etag_без_кешу_не_віддається
    path = File.join(@cache, 'nope.json')
    File.write("#{path}.etag", 'W/"abc123"')
    assert_nil Pure.read_etag(path)
  end

  # ETag іде в заголовок If-None-Match. Ruby відкидає CR/LF сам,
  # але мегабайтне значення відправив би як є.
  def test_велетенський_etag_відкидається
    path = File.join(@cache, 'alerts.json')
    File.write(path, '{"states":{}}')
    File.write("#{path}.etag", 'A' * 100_000)
    assert_nil Pure.read_etag(path)
  end

  def test_etag_з_переносом_рядка_відкидається
    path = File.join(@cache, 'alerts.json')
    File.write(path, '{"states":{}}')
    File.write("#{path}.etag", %(x\r\nX-Injected: 1))
    assert_nil Pure.read_etag(path)
  end

  # Схема перевірялась лише на записі, тож пошкоджений кеш повертався як є
  def test_кеш_з_невідомою_схемою_не_використовується
    path = File.join(@cache, 'Cherkasyoblenergo.json')
    File.write(path, JSON.generate('fact' => { 'data' => { 'не-дата' => {} } }))
    assert_nil Pure.read_schedule(path)
  end

  def test_справний_кеш_графіка_приймається
    ts = Time.new(Date.today.year, Date.today.month, Date.today.day).to_i
    path = File.join(@cache, 'Cherkasyoblenergo.json')
    File.write(path, JSON.generate(
                       'fact' => { 'data' => { ts.to_s => {
                         'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] }
                       } } }
                     ))
    refute_nil Pure.read_schedule(path)
  end

  def test_рядки_alerts_energy_з_дивною_чергою_відкидаються
    refute Pure.valid_rows?([{ 'queue' => '1.1 bash=/bin/sh' }])
    refute Pure.valid_rows?([{ 'queue' => 'x' }])
    refute Pure.valid_rows?('не масив')
    assert Pure.valid_rows?([{ 'queue' => '1.1' }])
    assert Pure.valid_rows?([])
  end
end

# Зловмисна програма без особливих прав може підкласти в кеш символьне
# посилання на будь-який файл користувача. Доки запис ішов через File.write,
# ми перезаписували ціль даними з мережі.
# Графік — це київські години. На маку з іншим поясом ті самі дані
# давали протилежну відповідь: у Києві «світла немає», у Лісабоні «світло є».
# Порожній графік — це «не знаємо», а не «світла вдосталь». Раніше
# Одеса з нульовими даними малювала зелену 💡.
class TestEmptySchedule < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-empty')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    w('sd-cherkaska-oblast', [])
    w('alerts', 'states' => {})
    w('energy', [])
    w('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_порожній_графік_не_видає_себе_за_світло
    w('Cherkasyoblenergo', 'fact' => { 'data' => {} }, 'lastUpdated' => Time.now.iso8601)
    out = run_plugin

    assert_match(/❔/, out.lines.first, 'порожній графік показано як «світло є»')
    refute_match(/💡/, out.lines.first)
    # «Тривоги немає» лишається зеленим законно — зелений не має бути
    # лише там, де йдеться про графік
    schedule_line = out.lines.find { |l| l.include?('графіка немає') }
    refute_nil schedule_line
    refute_match(/color=green/, schedule_line)
  end

  def test_порожній_графік_не_показує_сирий_час
    w('Cherkasyoblenergo', 'fact' => { 'data' => {} }, 'lastUpdated' => Time.now.iso8601)
    refute_match(/\d{4}-\d\d-\d\dT/, run_plugin, 'ISO-штамп замість людської дати')
  end
end

class TestTimezone < Minitest::Test
  ZONES = ['Europe/Kyiv', 'Europe/Lisbon', 'America/New_York', 'Asia/Tokyo', 'UTC'].freeze

  def setup
    @home = Dir.mktmpdir('blackout-tz')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    File.write(File.join(@home, '.config', 'blackout.json'),
               JSON.generate('region' => 'Cherkasyoblenergo', 'queue' => 'GPV1.1',
                             'notify' => false, 'alerts' => false))
    # Доба за київським часом, світло лише в першій половині
    day = Date.today
    ts = Time.new(day.year, day.month, day.day).to_i
    hours = (1..24).to_h { |i| [i.to_s, i <= 12 ? 'yes' : 'no'] }
    w('Cherkasyoblenergo', 'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => hours } },
                                       'today' => ts })
    w('sd-cherkaska-oblast', [])
    w('alerts', 'states' => {})
    w('energy', [])
    w('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  def test_відповідь_однакова_у_будь_якому_поясі
    answers = ZONES.map do |tz|
      out, = Open3.capture3({ 'HOME' => @home, 'TZ' => tz }, 'ruby', PLUGIN)
      [tz, out.lines.first.to_s.strip]
    end
    first = answers.first.last
    refute_empty first
    answers.each do |tz, line|
      assert_equal first, line, "пояс #{tz} дав іншу відповідь"
    end
  end
end

# Перший запуск не має вдавати, ніби Черкащина — це область користувача
class TestFirstRun < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-first')
    FileUtils.mkdir_p(File.join(@home, '.cache', 'blackout'))
    FileUtils.mkdir_p(File.join(@home, '.config'))
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def run_plugin(*args)
    Open3.capture3({ 'HOME' => @home }, 'ruby', PLUGIN, *args).first
  end

  def test_без_конфігу_просить_вибрати_а_не_показує_чужий_графік
    out = run_plugin
    assert_match(/Регіон не вибрано/, out)
    refute_match(/Черкаська обл\. · черга/, out, 'показано чужу область як свою')
    refute_match(/через \d+:\d\d/, out, 'показано відлік для невибраної області')
  end

  def test_екран_вибору_не_ходить_у_мережу
    out = run_plugin
    assert_empty Dir.children(File.join(@home, '.cache', 'blackout')),
                 'на екрані вибору запитів бути не повинно'
    assert_match(/черга 1\.1/, out)
  end

  def test_нічого_не_позначено_галочкою
    refute_match(/✓/, run_plugin, 'до вибору галочки стояти не має')
  end

  def test_кожна_область_має_посилання_на_обленерго
    out = run_plugin
    regions = out.lines.count { |l| l.chomp.match?(/\A[^-].* \| size=11\z/) }
    links = out.lines.count { |l| l.start_with?('--Не знаю свою чергу') }
    assert_operator regions, :>=, 26
    assert_equal regions, links
  end

  def test_після_вибору_показує_графік
    run_plugin('--set', 'Lvivoblenerho', 'GPV3.2')
    cfg = JSON.parse(File.read(File.join(@home, '.config', 'blackout.json')))
    assert_equal 'Lvivoblenerho', cfg['region']
    assert_equal 'GPV3.2', cfg['queue']
    refute_match(/Регіон не вибрано/, run_plugin)
  end
end

class TestSymlinkSafety < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-symlink')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    @victim = File.join(@home, 'victim.txt')
    File.write(@victim, "важливі дані\n")
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def test_запис_не_йде_за_посиланням
    path = File.join(@cache, 'alerts.json')
    File.symlink(@victim, path)
    Pure.atomic_write(path, '{"states":{}}')

    assert_equal "важливі дані\n", File.read(@victim), 'жертву перезаписано'
    refute File.symlink?(path), 'посилання мало зникнути'
    assert_equal '{"states":{}}', File.read(path)
  end

  def test_touch_не_чіпає_посилання
    path = File.join(@cache, 'alerts.json')
    File.symlink(@victim, path)
    before = File.mtime(@victim)
    Pure.touch_cache(path)

    assert_equal before, File.mtime(@victim), 'час жертви змінено'
  end

  def test_touch_оновлює_звичайний_файл
    path = File.join(@cache, 'alerts.json')
    File.write(path, '{}')
    File.utime(Time.now - 3600, Time.now - 3600, path)
    Pure.touch_cache(path)

    assert_operator File.mtime(path), :>, Time.now - 60
  end

  def test_запис_атомарний_і_без_смiття
    path = File.join(@cache, 'alerts.json')
    Pure.atomic_write(path, 'x' * 1000)

    assert_equal 1000, File.size(path)
    assert_empty Dir.glob("#{path}*.tmp"), 'тимчасовий файл не прибрано'
  end

  def test_невдалий_запис_не_лишає_tmp
    path = File.join(@home, 'немає-такої-теки', 'alerts.json')
    assert_raises(StandardError) { Pure.atomic_write(path, '{}') }
    assert_empty Dir.glob(File.join(@home, '**', '*.tmp'))
  end

  # Якщо посиланням є сама тека, ми писали б свої файли в чужу
  def test_тека_посилання_відмова
    other = File.join(@home, 'чужа')
    FileUtils.mkdir_p(other)
    link = File.join(@home, 'link-cache')
    File.symlink(other, link)

    assert_raises(RuntimeError) { Pure.ensure_dir(link) }
    assert_empty Dir.children(other)
  end

  def test_нова_тека_кешу_лише_для_власника
    dir = File.join(@home, 'fresh', 'blackout')
    Pure.ensure_dir(dir)

    assert_equal 0o700, File.stat(dir).mode & 0o777
  end
end

class TestDistrict < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-district')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    d = Date.today
    ts = Time.new(d.year, d.month, d.day).to_i
    w('sd-cherkaska-oblast', [])
    w('Cherkasyoblenergo',
      'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } } }, 'today' => ts })
    w('energy', [])
    w('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  # Тривога лише в Черкаському районі, користувач в Уманському
  def alerts_in(*hot)
    districts = ['Уманський район', 'Черкаський район'].to_h do |n|
      [n, { 'enabled' => hot.include?(n), 'alert_level' => 'yellow',
            'enabled_at' => Time.now.utc.iso8601 }]
    end
    w('alerts', 'states' => { 'Черкаська область' => {
         'enabled' => false, 'alert_level' => nil, 'districts' => districts
       } })
  end

  def run_plugin(env = {})
    base = { 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
             'BLACKOUT_QUEUE' => 'GPV1.1' }
    Open3.capture3(base.merge(env), 'ruby', PLUGIN).first
  end

  def test_чужий_район_не_показує_тривогу
    alerts_in('Черкаський район')
    out = run_plugin('BLACKOUT_DISTRICT' => 'Уманський район')
    assert_match(/Тривоги немає/, out)
    refute_match(/🟡/, out.lines.first)
  end

  def test_свій_район_показує_тривогу
    alerts_in('Уманський район')
    out = run_plugin('BLACKOUT_DISTRICT' => 'Уманський район')
    assert_match(/Тривога — дрони/, out)
    assert_match(/Уманський район · триває/, out)
  end

  def test_без_вибору_береться_вся_область
    alerts_in('Черкаський район')
    out = run_plugin
    assert_match(/Тривога — дрони/, out)
    assert_match(/Черкаська область/, out)
  end

  def test_тривога_на_всю_область_стосується_всіх
    # Оголошення по області значуще навіть для того, хто обрав район
    w('alerts', 'states' => { 'Черкаська область' => {
         'enabled' => true, 'alert_level' => 'red',
         'enabled_at' => Time.now.utc.iso8601, 'districts' => {}
       } })
    out = run_plugin('BLACKOUT_DISTRICT' => 'Уманський район')
    assert_match(/ракетна загроза/, out)
    assert_match(/Уся область/, out)
  end

  def test_назва_району_з_інєкцією_ігнорується
    alerts_in('Уманський район')
    out = run_plugin('BLACKOUT_DISTRICT' => 'Уманський bash=/bin/sh')
    refute_match(%r{bash=/bin/sh}, out)
  end
end

class TestLimits < Minitest::Test
  def test_safe_обрізає_довгий_текст
    # Заголовок на 100 КБ розтягнув би пункт меню на весь екран
    out = Pure.safe('A' * 100_000)
    assert_operator out.length, :<=, 201
    assert out.end_with?('…')
  end

  def test_safe_не_чіпає_коротке
    assert_equal 'Новина', Pure.safe('Новина')
  end

  def test_safe_приймає_власну_межу
    assert_equal 'abc…', Pure.safe('abcdefgh', 3)
  end
end

class TestOversizedData < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-big')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    d = Date.today
    @ts = Time.new(d.year, d.month, d.day).to_i
    w('energy', [])
    w('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_сотні_районів_не_розпирають_меню
    districts = (0...500).to_h do |i|
      ["Район #{i}", { 'enabled' => true, 'alert_level' => 'red',
                       'enabled_at' => Time.now.utc.iso8601 }]
    end
    w('sd-cherkaska-oblast', [])
    w('Cherkasyoblenergo',
      'fact' => { 'data' => { @ts.to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } } },
                  'today' => @ts })
    w('alerts', 'states' => { 'Черкаська область' => {
         'enabled' => false, 'alert_level' => 'red', 'districts' => districts
       } })
    out = run_plugin
    line = out.lines.find { |l| l.start_with?('Райони:') }
    refute_nil line
    assert_operator line.length, :<, 300
    assert_match(/та ще \d+/, line)
  end

  def test_жоден_рядок_не_довший_за_розумне
    w('sd-cherkaska-oblast', [])
    w('Cherkasyoblenergo',
      'fact' => { 'update' => 'U' * 50_000,
                  'data' => { @ts.to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } } },
                  'today' => @ts })
    w('alerts', 'states' => {})
    w('notice', 'breaking' => { 'title' => 'T' * 50_000, 'excerpt' => 'E' * 50_000 })
    longest = run_plugin.lines.map(&:length).max
    assert_operator longest, :<, 500, 'рядок меню не має бути нескінченним'
  end
end
