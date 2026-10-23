REGIONS = {
  # id => [menu label, mirror, oblast, utility site, primary-source slug]
  'Prykarpattiaoblenerho'    => ['Івано-Франківська', :oe, 'Івано-Франківська область', 'https://www.oe.if.ua/', 'ivano-frankivska-oblast'],
  'avtonomna-respublika-krym' => ['АР Крим', nil, 'Автономна Республіка Крим', 'https://alerts.energy/avtonomna-respublika-krym', 'avtonomna-respublika-krym'],
  'volynska-oblast'          => ['Волинська обл.', nil, 'Волинська область', 'https://alerts.energy/volynska-oblast', 'volynska-oblast'],
  'vinnytska-oblast'         => ['Вінницька обл.', nil, 'Вінницька область', 'https://alerts.energy/vinnytska-oblast', 'vinnytska-oblast'],
  'dnipro'                   => ['Дніпро та обл.', :bk, 'Дніпропетровська область', 'https://www.dtek-dnem.com.ua/ua/shutdowns', 'dnipropetrovska-oblast'],
  'donetska-oblast'          => ['Донецька обл.', nil, 'Донецька область', 'https://alerts.energy/donetska-oblast', 'donetska-oblast'],
  'Zhytomyroblenergo'        => ['Житомирська обл.', :oe, 'Житомирська область', 'https://www.ztoe.com.ua/unhooking-search.php', 'zhytomyrska-oblast'],
  'Zakarpattiaoblenerho'     => ['Закарпатська обл.', :oe, 'Закарпатська область', 'https://www.zakarpat.energy/', 'zakarpatska-oblast'],
  'Zaporizhzhiaoblenergo'    => ['Запорізька обл.', :oe, 'Запорізька область', 'https://www.zoe.com.ua/', 'zaporizka-oblast'],
  'kyiv-region'              => ['Київська обл.', :bk, 'Київська область', 'https://www.dtek-krem.com.ua/ua/shutdowns', 'kyivska-oblast'],
  'kirovogradska-oblast'     => ['Кіровоградська обл.', nil, 'Кіровоградська область', 'https://alerts.energy/kirovogradska-oblast', 'kirovogradska-oblast'],
  'luganska-oblast'          => ['Луганська обл.', nil, 'Луганська область', 'https://alerts.energy/luganska-oblast', 'luganska-oblast'],
  'Lvivoblenerho'            => ['Львівська обл.', :oe, 'Львівська область', 'https://loe.lviv.ua/', 'lvivska-oblast'],
  'mikolayivska-oblast'      => ['Миколаївська обл.', nil, 'Миколаївська область', 'https://alerts.energy/mikolayivska-oblast', 'mikolayivska-oblast'],
  'odesa'                    => ['Одеса та обл.', :bk, 'Одеська область', 'https://www.dtek-oem.com.ua/ua/shutdowns', 'odeska-oblast'],
  'Poltavaoblenergo'         => ['Полтавська обл.', :oe, 'Полтавська область', 'https://www.poe.pl.ua/', 'poltavska-oblast'],
  'Rivneoblenergo'           => ['Рівненська обл.', :oe, 'Рівненська область', 'https://www.roe.vsei.ua/', 'rivnenska-oblast'],
  'sumska-oblast'            => ['Сумська обл.', nil, 'Сумська область', 'https://alerts.energy/sumska-oblast', 'sumska-oblast'],
  'Ternopiloblenerho'        => ['Тернопільська обл.', :oe, 'Тернопільська область', 'https://www.toe.com.ua/', 'ternopilska-oblast'],
  'Kharkivoblenerho'         => ['Харківська обл.', :oe, 'Харківська область', 'https://www.hoe.com.ua/', 'kharkivska-oblast'],
  'khersonska-oblast'        => ['Херсонська обл.', nil, 'Херсонська область', 'https://alerts.energy/khersonska-oblast', 'khersonska-oblast'],
  'Khmelnytskoblenerho'      => ['Хмельницька обл.', :oe, 'Хмельницька область', 'https://www.hoe.com.ua/', 'khmelnytska-oblast'],
  'Cherkasyoblenergo'        => ['Черкаська обл.', :oe, 'Черкаська область', 'https://www.cherkasyoblenergo.com/static/perelik-gpv', 'cherkaska-oblast'],
  'chernivecka-oblast'       => ['Чернівецька обл.', nil, 'Чернівецька область', 'https://alerts.energy/chernivecka-oblast', 'chernivecka-oblast'],
  'Chernihivoblenergo'       => ['Чернігівська обл.', :oe, 'Чернігівська область', 'https://www.chernihiv.energy/', 'chernigivska-oblast'],
  'kyiv'                     => ['Київ', :bk, 'м. Київ', 'https://kyiv.yasno.com.ua/schedule-turn-off-electricity', 'kyiv']
}.freeze

SRC = { oe: OE_SRC, bk: BK_SRC }.freeze

