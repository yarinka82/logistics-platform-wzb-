# SmartLog Europe — Database Schema Technical Documentation

**File:** `DATABASE_SCHEMA.md`  
**Source DDL:** `001_smartlog_core_mvp_marketplace_schema.sql`  
**Target DB:** PostgreSQL 14+  
**Extension:** PostGIS  
**Schema type:** Core logistics / marketplace MVP  
**Documentation language:** Ukrainian

---

## 1. Призначення

Цей документ описує фактичну структуру та логіку SQL-скрипту `01_smartlog_core_mvp_marketplace_schema.sql`.

База даних **SmartLog Europe** призначена для ядра логістичної платформи з такими функціональними напрямами:

- marketplace matching для прямих замовлень;
- клієнти та контрагенти;
- самозайняті водії та водії транспортних компаній;
- автопарк і транспортні засоби, включно з юридичним власником ТЗ;
- маршрути та геопросторові дані PostGIS;
- фізичне виконання доставок;
- GPS-телематика;
- e-CMR / e-POD та інші документи;
- операційні та транспортні витрати;
- VAT / Reverse Charge логіка;
- live-аналітика через SQL views;
- оцінювання надійності та service compliance водіїв;
- PostgreSQL `NOTIFY` для real-time подій.

Архітектура орієнтована на MVP у Німеччині з підготовленою структурою для подальшої активації інших країн ЄС.

---

## 2. Технологічні вимоги

### 2.1. PostgreSQL

DDL розрахований на **PostgreSQL 14 або новішу версію**.

### 2.2. PostGIS

На початку SQL-файлу виконується:

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
```

PostGIS використовується для:

- GPS-точок;
- геометрії планових маршрутів;
- просторових індексів `GIST`;
- розрахунку відстані між фактичними GPS-точками та плановим маршрутом;
- побудови фактичної траєкторії доставки.

---

## 3. Загальна логічна модель

Основний потік даних:

```text
supported_countries
       │
       ├── vat_rates
       │
       ├── clients
       │      │
       │      ├── orders
       │      │      │
       │      │      └── deliveries
       │      │              ├── delivery_track_points
       │      │              ├── shipment_documents
       │      │              └── costs
       │      │
       │      ├── drivers (linked_client_id, nullable)
       │      │
       │      └── vehicles (owner_client_id, nullable)
       │
       └── routes
                │
                └── deliveries

drivers ───────────────┐
   │                   │
   └── default_vehicle │
                       │
vehicles ──────────────┘

costs ──► drivers
costs ──► vehicles
costs ──► deliveries
```

### Основні залежності

| Батьківська таблиця | Дочірня таблиця | Зв'язок |
|---|---|---|
| `supported_countries` | `vat_rates` | 1:N |
| `supported_countries` | `clients` | 1:N |
| `supported_countries` | `routes` | 1:N через країни origin/destination |
| `supported_countries` | `orders` | 1:N через origin/destination |
| `clients` | `orders` | 1:N |
| `clients` | `drivers` | 1:N, nullable (`linked_client_id`) |
| `clients` | `vehicles` | 1:N, nullable (`owner_client_id`) — **додано 2026-09-16** |
| `vehicles` | `drivers` | 1:N як `default_vehicle_id`, nullable |
| `orders` | `deliveries` | 1:N на рівні FK |
| `routes` | `deliveries` | 1:N |
| `drivers` | `deliveries` | 1:N, nullable |
| `vehicles` | `deliveries` | 1:N, nullable |
| `deliveries` | `delivery_track_points` | 1:N |
| `deliveries` | `shipment_documents` | 1:N |
| `deliveries` | `costs` | 1:N, nullable |
| `drivers` | `costs` | 1:N, nullable |
| `vehicles` | `costs` | 1:N, nullable |

> Важливо: SQL не встановлює `UNIQUE(order_id)` у `deliveries`, тому на рівні самої БД зв'язок `orders → deliveries` технічно є **1:N**, а не гарантованим 1:1.

> **Юридична власність vs поточне закріплення ТЗ.** `vehicles.owner_client_id` — це власник/оператор транспортного засобу (юридичний факт), тоді як ланцюжок `vehicles ← drivers.default_vehicle_id ← drivers.linked_client_id` показує лише ПОТОЧНЕ закріплення конкретного водія за авто (операційний факт). Це два різні зв'язки з різним бізнес-змістом, і до 2026-09-16 прямого юридичного зв'язку "чиє це авто" в схемі не було взагалі.

---

## 4. ENUM-типи

### `client_type_enum`

Визначає тип контрагента:

- `individual` — приватний B2C клієнт;
- `company` — B2B компанія;
- `solo_carrier` — самозайнятий перевізник, зареєстрований на біржі.

### `driver_type_enum`

- `self_employed` — самозайнятий водій;
- `company_employee` — водій транспортної компанії.

### `driver_status_enum`

- `available` — доступний;
- `on_trip` — виконує рейс;
- `off_duty` — поза робочим часом / перерва;
- `inactive` — неактивний або заблокований.

### `order_status_enum`

Життєвий цикл замовлення:

```text
draft
  ↓
published
  ↓
confirmed
  ↓
in_transit
  ↓
delivered

cancelled — альтернативний завершальний стан
```

### `match_status_enum`

Стан двостороннього matching:

- `pending`;
- `both_confirmed`;
- `rejected`.

### `executor_type_enum`

- `fop_driver` — самозайнятий водій;
- `carrier_company` — транспортна компанія / субпідрядник.

### `cargo_type_enum`

- `box`;
- `pallet`;
- `parcel`;
- `bulk`;
- `fragile`;
- `other`.

### `delivery_status_enum`

- `planned`;
- `in_transit`;
- `delivered`;
- `cancelled`.

### `delay_status_enum`

- `on_time`;
- `delayed`.

### `delay_reason_enum`

- `traffic`;
- `weather`;
- `loading_delay`;
- `customer_delay`;
- `vehicle_issue`;
- `route_issue`;
- `other`.

### `incident_type_enum`

- `None`;
- `Traffic_Stau`;
- `Weather_Force_Majeure`;
- `Dock_Waiting`;
- `Vehicle_Breakdown`;
- `Driver_Route_Deviation`;
- `Cargo_Handling_Damage`;
- `Paperwork_CMR_Error`.

### `cost_type_enum`

- `fuel`;
- `maintenance`;
- `work_reward`;
- `other`.

### `document_type_enum`

- `electronic_cmr`;
- `delivery_photo`;
- `damage_act`;
- `weight_ticket`;
- `invoice`.

### `document_status_enum`

- `pending`;
- `confirmed`;
- `rejected`.

---

## 5. Таблиці

## 5.1. `supported_countries`

Довідник країн, які можуть бути активовані для роботи платформи.

| Поле | Тип | Обмеження / призначення |
|---|---|---|
| `country_code` | `CHAR(2)` | PK, ISO alpha-2 |
| `country_name` | `VARCHAR(100)` | NOT NULL |
| `is_active` | `BOOLEAN` | DEFAULT FALSE |
| `activated_at` | `TIMESTAMPTZ` | Час активації |

Є `CHECK`, який вимагає формат двох великих латинських літер.

У seed-даних активна лише Німеччина (`DE`). Інші перелічені країни ЄС створені як неактивні.

---

## 5.2. `vat_rates`

Історія стандартних ставок VAT.

| Поле | Тип | Призначення |
|---|---|---|
| `vat_rate_id` | `SMALLINT IDENTITY` | PK |
| `country_code` | `CHAR(2)` | FK → `supported_countries` |
| `standard_rate_pct` | `NUMERIC(4,2)` | Ставка VAT |
| `valid_from` | `DATE` | Початок дії |
| `valid_to` | `DATE` | Кінець дії, nullable |

Створений partial unique index:

```text
idx_vat_rates_current_per_country
```

Він не дозволяє мати більше одного запису з `valid_to IS NULL` для однієї країни.

Для Німеччини seed-дані містять ставку `19.00%` з `2007-01-01`.

---

## 5.3. `clients`

Основна таблиця клієнтів і контрагентів.

Ключові дані:

- ідентифікатор;
- тип клієнта;
- юридичне ім'я;
- VAT ID;
- податковий номер;
- контактні дані;
- billing address;
- країна;
- статус верифікації **+ журнал верифікації**;
- активність;
- timestamps.

### Журнал верифікації (додано 2026-09-16)

| Поле | Тип | Призначення |
|---|---|---|
| `verified_by` | `VARCHAR(150)` | Email/ID співробітника або системи, що верифікувала клієнта |
| `verified_at` | `TIMESTAMPTZ` | Дата й час фактичної верифікації |

До цієї зміни `is_verified` був "голим" прапорцем без аудиту: встановити, хто і коли фактично підтвердив клієнта, було неможливо.

### Бізнес-обмеження

Для `client_type = 'company'` необхідно мати хоча б один із:

- `vat_id`;
- `tax_number`.

Для `individual` і `solo_carrier` ця вимога не застосовується.

**`CONSTRAINT chk_client_verification_log`** (додано 2026-09-16): узгоджує `is_verified` із журналом — обидва поля `verified_by`/`verified_at` мають бути або порожні одночасно (клієнт ще не верифікований), або заповнені одночасно (верифікований). Неможливо мати `is_verified = TRUE` без зафіксованого автора й часу верифікації, і навпаки.

Перед вставкою або зміною `billing_country` trigger перевіряє, чи країна активна.

---

## 5.4. `vehicles`

Довідник транспортних засобів.

Ключові поля:

- `vehicle_id`;
- `license_plate`;
- `vehicle_type`;
- `gross_vehicle_weight_kg`;
- `payload_capacity_kg`;
- `pallet_capacity`;
- `fuel_type`;
- `euro_emission_class`;
- `tuv_inspection_expiry_date`;
- `is_active`;
- `is_test`;
- **`owner_client_id`** — додано 2026-09-16.

`license_plate` має `UNIQUE`.

Поля маси та вантажопідйомності мають позитивні значення.

### Юридичний власник ТЗ (додано 2026-09-16)

`owner_client_id VARCHAR(32) REFERENCES clients(client_id) ON UPDATE CASCADE ON DELETE SET NULL` — прямий зв'язок з юридичним власником/оператором ТЗ: компанія-перевізник (`client_type='company'`) або сам самозайнятий перевізник як власна юр. особа (`client_type='solo_carrier'`).

До цієї зміни зв'язок "чиє це авто" можна було встановити лише непрямим ланцюжком `vehicles.vehicle_id ← drivers.default_vehicle_id → drivers.linked_client_id`, що показує лише поточне закріплення водія за авто, а не юридичну власність, і взагалі не працює для авто зовнішніх `carrier_company`, які не реєструють власних водіїв у `drivers`.

Індекс: `idx_vehicles_owner_client_id`.

> **Відома відкрита прогалина (задокументовано в SQL, §10.5):** для авто штатних водіїв (`company_employee`), у яких немає окремого `client`-запису, що представляв би саму операційну компанію-власника автопарку, `owner_client_id` лишається `NULL`. Потрібно завести такий client-запис — рішення відкладено до наступної ітерації MVP за домовленістю з власницею продукту.

---

## 5.5. `drivers`

Профіль водія або самозайнятого кур'єра.

Містить:

- тип зайнятості;
- прив'язку до клієнта (`linked_client_id`);
- контактні дані;
- місто базування;
- категорії водійського посвідчення;
- Code 95;
- ADR (`has_adr`, `adr_expiry_date`);
- customer rating;
- кількість відгуків;
- service compliance rate;
- операційний статус;
- default vehicle (`default_vehicle_id`).

### Узгодженість Code 95

Якщо вказано `code_95_categories`, обов'язково має бути вказано `code_95_expiry_date`, і навпаки.

### Узгодженість ADR

Якщо `has_adr = TRUE`, обов'язково має бути `adr_expiry_date`.

> Це перевіряє лише внутрішню узгодженість полів усередині `drivers`. Звірку `has_adr` водія з вимогою `orders.adr_required` конкретного замовлення виконує окремий тригер — див. §8.5.

### Узгодженість `driver_type` ↔ `linked_client_id` (оновлено 2026-09-23, замінює рішення від 2026-09-20)

`linked_client_id` тепер `NOT NULL` і ЗАВЖДИ має вказувати на `clients`-запис правильного типу, для обох типів водіїв:

- `driver_type = 'self_employed'` → `linked_client_id` обов'язковий, вказує на `client_type = 'solo_carrier'`;
- `driver_type = 'company_employee'` → `linked_client_id` обов'язковий, вказує на `client_type = 'company'`.

Причина зміни: за ТЗ Product Manager найманого водія створює власник фірми напряму (кнопка "+ Додати водія" у кабінеті, система сама шле SMS + тимчасовий PIN для входу) — окремої самореєстрації для найманого водія в продукті немає, тож `linked_client_id` відомий одразу в момент створення запису. `ON DELETE` для FK змінено з `SET NULL` на `RESTRICT` — видалити `client`, поки на нього посилається хоч один водій, не можна (захист від "осиротілих" записів).

Детальніше про бізнес-логіку та SQL — див. §8.6.

### Авто-блокування (додано 2026-09-23)

`blocked_at`, `blocked_reason` — аудит-поля, які заповнює тригер `fn_evaluate_driver_auto_block`, коли `status` автоматично переходить у `inactive`. Дивись §8.8 та §5.12 (`fraud_reports`).

---

## 5.6. `routes`

Планові логістичні коридори.

| Поле | Призначення |
|---|---|
| `route_id` | PK |
| `route_name` | Назва маршруту |
| `planned_geometry` | PostGIS `LineString`, SRID 4326. **`NULL`-able з 2026-09-23** |
| `planned_distance_km` | Планова відстань (обов'язкова) |
| `origin_country` | Країна початку |
| `destination_country` | Країна призначення |
| `is_cross_border` | Generated column |

`is_cross_border` обчислюється як:

```sql
origin_country <> destination_country
```

Просторова геометрія має `GIST` index.

> **`planned_geometry` тепер необов'язкова (додано 2026-09-23).** За спрощеною MVP-логікою PM бекенд не малює реальний маршрут на мапі — досить `planned_distance_km` (введена вручну або оцінена по прямій) і GPS-точок у `delivery_track_points`, які фіксуються при натисканні кнопок водієм ("Виїхав" / "Прибув" / "Доставив"), а не безперервним трекінгом. Функція `is_route_deviated()` (§9 — PostGIS-функції) вже коректно обробляла `NULL`-геометрію (повертає `NULL` замість помилки) — перевірено наживо, зміна нічого не ламає. Геометрія заповнюється пізніше, коли з'явиться модуль побудови реального маршруту.

---

## 5.7. `orders`

Центральна сутність marketplace.

Замовлення містить:

- клієнта;
- дату;
- статус;
- суму;
- VAT;
- Reverse Charge;
- адреси та GPS origin/destination;
- pickup/delivery windows;
- cargo parameters, включно з `adr_required`;
- executor;
- двосторонні підтвердження;
- match status.

> **Перевірено (2026-09-16):** колонки `client_name` у цій таблиці ніколи не було в канонічній схемі — клієнт ідентифікується виключно через `client_id` (FK → `clients`). Дублююча колонка `client_name` існувала лише в тестовому Excel-файлі (для зручності читання людиною) і була звідти видалена.

### Просторові поля

```text
origin_location       GEOMETRY(Point, 4326)
destination_location  GEOMETRY(Point, 4326)
```

### Matching

Дані:

- `executor_type`;
- `executor_id`;
- `executor_name`;
- `shipper_confirmed`;
- `shipper_confirmed_at`;
- `carrier_confirmed`;
- `carrier_confirmed_at`;
- `match_status`.

Є constraint:

```text
match_status = both_confirmed
```

дозволяється лише тоді, коли обидві сторони підтвердили готовність.

### ADR-вантаж (`adr_required`)

Якщо `adr_required = TRUE`, і виконавець — `fop_driver`, тригер `trg_validate_order_adr_compliance` (додано 2026-09-16, див. §8.5) перевіряє, що призначений водій дійсно має `drivers.has_adr = TRUE`.

### VAT

Якщо `is_reverse_charge = TRUE`, `vat_rate_pct` повинен бути `0.00`.

Окремий trigger автоматично визначає VAT.

### Фінальне підтвердження — статус `closed` (додано 2026-09-23)

`order_status_enum` доповнено значенням `closed`, яке йде після `delivered`. Різниця:

- `delivered` — водій сам натиснув "Доставлено" (у мобільному додатку);
- `closed` — окремо клієнт або бухгалтер підтвердив, що все гаразд, і рахунок можна виставляти (ТЗ PM: "Бухгалтер чи замовник натиснув кнопку 'Зроблено'/'Затверджено'").

Аудит: `closed_by` (email/ID того, хто підтвердив), `closed_at`. `CONSTRAINT chk_order_closed_log` вимагає, щоб обидва поля були заповнені разом зі статусом `closed` (і порожні в будь-якому іншому статусі) — той самий патерн, що й `chk_client_verification_log` у `clients`.

> Назва навмисно `closed`, а не `confirmed` — значення `confirmed` в цьому ж enum вже зайняте станом "виконавця підтверджено обома сторонами" (`match_status = both_confirmed`), і використання його вдруге для іншого сенсу заплутало б аналітику.

> **Відома межа (не вирішено зараз):** CHECK-constraint не може перевірити послідовність переходів (наприклад, заборонити `closed` одразу з `draft`, минаючи `delivered`) — це вимагає окремого BEFORE UPDATE-тригера. Поки що контроль порядку статусів лишається на бекенді.

---

## 5.8. `deliveries`

Фактичне виконання транспортного замовлення.

Містить:

- order;
- route;
- driver;
- vehicle;
- планові та фактичні timestamps;
- планову та фактичну відстань;
- duration;
- delay;
- incident;
- driver liability;
- customer rating;
- feedback;
- e-POD URL.

### Delay

Зберігаються:

- `delay_minutes`;
- `delay_status`;
- `delay_reason`.

### Compliance

Поле `is_driver_liable` використовується під час розрахунку Incident-Free Rate.

---

## 5.9. `delivery_track_points`

Телематичні GPS-точки.

Кожен запис містить:

- `track_point_id`;
- `delivery_id`;
- `recorded_at`;
- `location`;
- `speed_kmh`.

`location` — `GEOMETRY(Point, 4326)`.

Є два ключові індекси:

```text
idx_track_points_delivery
idx_track_points_geom
```

Перший оптимізує вибірку точок конкретної доставки за часом, другий — просторові операції.

---

## 5.10. `shipment_documents`

Електронний документообіг та метадані файлів доставки.

> **Архітектурне правило:** Фізичні бінарні файли (PDF e-CMR, фотопідтвердження e-POD, акти пошкоджень) зберігаються в об'єктному сховищі (S3 / MinIO). База даних PostgreSQL зберігає виключно URL-адреси, S3-ключі та технічні метадані файлів.

| Поле | Тип | Обмеження / Призначення |
|---|---|---|
| `document_id` | `VARCHAR(32)` | PK, єдиний шаблон `DOC-YYYY-######` |
| `delivery_id` | `VARCHAR(32)` | FK → `deliveries(delivery_id)` ON UPDATE CASCADE ON DELETE CASCADE |
| `document_type` | `document_type_enum` | Словник: `electronic_cmr`, `delivery_photo`, `damage_act`, `weight_ticket`, `invoice` |
| `document_url` | `TEXT` | NOT NULL, пряме посилання або S3 Pre-signed URL / CDN шлях |
| `s3_object_key` | `VARCHAR(512)` | Ключ об'єкта в бакеті (наприклад, `documents/2026/cmr_DL101.pdf`) |
| `file_name` | `VARCHAR(255)` | NOT NULL, оригінальна назва файлу (наприклад, `cmr_scan.pdf`) |
| `file_size_bytes` | `BIGINT` | Розмір файлу в байтах для аудиту та контролю дискових квот S3 |
| `mime_type` | `VARCHAR(100)` | NOT NULL, DEFAULT `'application/pdf'` (наприклад, `image/jpeg`, `application/pdf`) |
| `verification_status` | `document_status_enum` | NOT NULL, DEFAULT `'pending'` (`pending`, `confirmed`, `rejected`) |
| `signed_by_name` | `VARCHAR(100)` | ПІБ особи, яка підписала документ / накладну |
| `signed_at` | `TIMESTAMPTZ` | Точні дата й час накладання електронного підпису |
| `signature_geo_location` | `GEOMETRY(Point, 4326)` | PostGIS координати місця підписання e-POD (WGS 84) |
| `rejection_reason` | `TEXT` | Причина відхилення документа бухгалтерією або замовником |
| `created_at` | `TIMESTAMPTZ` | DEFAULT CURRENT_TIMESTAMP |
| `updated_at` | `TIMESTAMPTZ` | DEFAULT CURRENT_TIMESTAMP |

### Індекси таблиці

```text
idx_shipment_docs_delivery   ON shipment_documents(delivery_id)
idx_shipment_docs_status     ON shipment_documents(verification_status)
```

---

## 5.11. `costs`

Єдина таблиця операційних і транспортних витрат.

### Основні групи

```text
fuel
maintenance
work_reward
other
```

### `cost_subtype`

Для fuel:

- `diesel`;
- `petrol`;
- `adblue`;
- `electricity`;
- `cng_lng`.

Для maintenance:

- `scheduled_service`;
- `tech_inspection`;
- `repair`;
- `tires`;
- `washing`.

Для work reward:

- `trip_fee`;
- `base_salary`;
- `per_diem`;
- `bonus`;
- `driver_allowance`.

Для other:

- `tolls`;
- `parking`;
- `fines`;
- `claims`;
- `insurance`;
- `ferry_bridge`.

`is_repair = TRUE` дозволено лише для `cost_type = 'maintenance'`.

---

## 5.12. `fraud_reports` (додано 2026-09-23)

Скарги клієнтів на водіїв ("Повідомити про шахрайство", ТЗ PM §6.2 "Саморегуляція біржі").

| Поле | Призначення |
|---|---|
| `report_id` | PK |
| `reported_driver_id` | FK → `drivers`, на кого скарга |
| `reporter_client_id` | FK → `clients`, хто поскаржився |
| `order_id` | FK → `orders`, необов'язковий контекст (у рамках якого замовлення) |
| `reason` | Текст скарги |
| `created_at` | Час подання |

> **Не для чого ця таблиця:** скарг на замовників тут немає (лише клієнт → водій, як описано в ТЗ), і немає захисту від зовнішніх атак (підбір паролів, DDoS, сканування неіснуючих адрес) — це свідомо залишено поза бізнес-БД, рекомендовано інфраструктурний рівень (WAF / rate-limiting), рішення власника продукту від 2026-09-23.
>
> **MVP-спрощення:** авто-блокування (§8.8) рахує СУМАРНУ кількість рядків на водія, а не буквальне "2 клієнти поспіль" з ТЗ — послідовність скарг у прив'язці до замовлень окремо не відстежується.

---

## 6. Foreign Keys та поведінка DELETE / UPDATE

Ключові правила:

### `ON UPDATE CASCADE`

Використовується для багатьох довідникових ідентифікаторів, зокрема:

- country references;
- client references;
- driver references;
- vehicle references;
- route references.

### `ON DELETE SET NULL`

Застосовується там, де видалення батьківського запису не повинно видаляти історичний запис:

- `drivers.linked_client_id`;
- `drivers.default_vehicle_id`;
- `vehicles.owner_client_id` — **додано 2026-09-16**;
- `costs.delivery_id`;
- `costs.driver_id`;
- `costs.vehicle_id`.

### `ON DELETE CASCADE`

Застосовується для дочірніх даних доставки:

- `delivery_track_points.delivery_id`;
- `shipment_documents.delivery_id`.

Це означає, що при видаленні delivery її GPS-точки та документи також видаляються.

---

## 7. Індекси

### Clients

```text
idx_clients_country_type
```

Оптимізує фільтрацію за країною та типом клієнта.

### Vehicles

```text
idx_vehicles_owner_client_id
```

Додано 2026-09-16 разом із `owner_client_id`. Оптимізує пошук усіх ТЗ конкретного власника.

### Orders

```text
idx_orders_client_id
idx_orders_status_date
idx_orders_match_status
idx_orders_origin_loc
idx_orders_dest_loc
idx_orders_client_tracking
```

Особливо важливі:

- `GIST` для spatial search;
- partial index `idx_orders_match_status`;
- composite index для keyset pagination.

### Routes

```text
idx_routes_geometry
idx_routes_cross_border
```

### Deliveries

```text
idx_deliveries_order_id
idx_deliveries_route_id
idx_deliveries_driver_status
idx_deliveries_vehicle_status
idx_deliveries_actual_end
```

### GPS

```text
idx_track_points_delivery
idx_track_points_geom
```

### Documents

```text
idx_shipment_docs_delivery
idx_shipment_docs_status
```

### Costs

```text
idx_costs_delivery_id
idx_costs_driver_date
idx_costs_vehicle_date
idx_costs_is_repair
idx_costs_subtype
```

---

## 8. Triggers та автоматична бізнес-логіка

## 8.1. Перевірка активної країни клієнта

`trg_before_client_country_check`

Перед INSERT/UPDATE перевіряє `clients.billing_country`.

Якщо країна не активна, операція завершується exception.

---

## 8.2. Перевірка країн замовлення

`trg_before_order_countries_check`

Перевіряє:

- `origin_country`;
- `destination_country`.

Обидві країни повинні мати `is_active = TRUE`.

---

## 8.3. Автоматичне визначення VAT

`trg_before_order_vat_rate`

Логіка:

```text
origin_country != destination_country
        │
        ├── TRUE → Reverse Charge = TRUE
        │          VAT = 0.00%
        │
        └── FALSE → пошук ставки у vat_rates
                    за order_date
                    ↓
                    запис vat_rate_pct
```

Таким чином, ставка VAT не повинна вручну задаватися application layer для стандартного сценарію.

---

## 8.4. Перевірка executor

`trg_before_order_executor_check`

Якщо:

```text
executor_type = fop_driver
```

і `executor_id` заданий, система перевіряє існування такого `driver_id`.

> Для `carrier_company` поточний trigger не перевіряє існування `executor_id` у `clients`. Це фактична поведінка поточного SQL.

---

## 8.5. Перевірка ADR-відповідності виконавця (додано 2026-09-16)

`trg_validate_order_adr_compliance` / `trg_before_order_adr_check`

Закриває прогалину, яка раніше існувала на рівні БД: `orders.adr_required` ніяк не звірявся з `drivers.has_adr` призначеного виконавця.

Побудовано за тим самим принципом, що й §8.4 (`trg_validate_order_executor`):

```text
IF adr_required = TRUE AND executor_type = 'fop_driver' AND executor_id IS NOT NULL:
    перевірити drivers.has_adr для executor_id
    IF has_adr IS NULL  → EXCEPTION (водія не знайдено)
    IF has_adr = FALSE  → EXCEPTION (водій без діючого ADR-сертифіката)
```

> Перевірка спрацьовує **лише** для `executor_type = 'fop_driver'`. Для `executor_type = 'carrier_company'` перевірка НЕ виконується — платформа не реєструє водіїв/сертифікати зовнішніх компаній-перевізників (та сама архітектурна межа, що й у §8.4).

Технічно перевірено на живій PostgreSQL 16 + PostGIS: сценарії "виконавець з ADR + adr_required=TRUE" (успіх), "виконавець без ADR + adr_required=TRUE" (exception), "adr_required=FALSE" (перевірка не спрацьовує), "executor_type=carrier_company" (перевірка не спрацьовує) — усі відпрацювали коректно.

---

## 8.6. Узгодженість `driver_type` ↔ `linked_client_id` (оновлено 2026-09-23, замінює рішення від 2026-09-20)

`trg_validate_driver_linked_client` / `trg_before_driver_linked_client_check`

**Бізнес-проблема:** до цієї зміни `drivers.linked_client_id` міг посилатися на будь-який запис у `clients`, незалежно від його `client_type`. Нічого не заважало (помилково, вручну або багом бекенду) прив'язати самозайнятого водія до компанії або навпаки — а це два принципово різні бізнес-сценарії: самозайнятий водій (`self_employed`) сам є білінговою/юридичною стороною (сплачує податки, отримує оплату напряму, може володіти власним авто через `vehicles.owner_client_id`), тоді як найманий водій (`company_employee`) — лише виконавець, гроші й юридична відповідальність йдуть через його роботодавця.

**Правило (з 2026-09-23):**

```text
IF linked_client_id IS NULL → EXCEPTION (обов'язковий для будь-якого driver_type)

перевірити clients.client_type для linked_client_id
    IF driver_type = 'self_employed'    AND client_type <> 'solo_carrier' → EXCEPTION
    IF driver_type = 'company_employee' AND client_type <> 'company'      → EXCEPTION
```

**Чому змінено (джерело: ТЗ Product Manager, `Logistik.docx`, розділ 7.1/9):** попереднє рішення (2026-09-20) виходило з того, що найманий водій реєструється сам, а власник підтверджує його пізніше — тому `company_employee` дозволялось тимчасово мати `linked_client_id = NULL`. ТЗ PM описує протилежний сценарій: **власник фірми сам створює запис водія** через кабінет (кнопка "+ Додати водія": ім'я, телефон, номер авто), і система автоматично шле SMS з посиланням і тимчасовим PIN для входу. Окремої форми самореєстрації для найманого водія на `/register` немає — лише 3 ролі: замовник / приватний водій / фірма. Отже, `linked_client_id` ЗАВЖДИ відомий у момент створення запису `driver`, і потреби в перехідному `NULL`-стані більше немає.

**Наслідок:** колонка `linked_client_id` тепер `NOT NULL` на рівні таблиці (було `NULL`-able), а `ON DELETE` для FK змінено з `SET NULL` на `RESTRICT` (видалити `client`, доки на нього посилається хоч один водій, не можна). Модуль запитів на доступ (`Design_App_Users_Access_Control_SmartLog_Europe.md` — `app_users` / `driver_company_requests` / `trg_sync_driver_company_link`) для цього сценарію більше не потрібен; документ лишається в Project Knowledge як зафіксована, але відхилена альтернатива (могла б знадобитись, якби продукт таки вирішив дозволити водіям самостійно "проситись" у компанію — окрема бізнес-фіча, не поточне ТЗ).

**Архітектурний наслідок для auth-шару (Django):** без змін порівняно з попередньою версією — окремий FK `Client` в `DriverProfile` (auth-шар) непотрібен, доступ до білінгових даних іде через `DriverProfile.driver → Driver.linked_client_id → Client`.

> DB-тригер спрацьовує лише в момент запису в БД (`IntegrityError`), а не при валідації форми. Для кращого UX цю саму перевірку варто продублювати в `Driver.clean()` на рівні Django — так само, як уже задокументовано для §8.5 (ADR).

Технічно перевірено на живій PostgreSQL 16 + PostGIS (2026-09-23, 5 сценаріїв на оновленій версії): `company_employee` без `linked_client_id` (exception — вже не дозволено), `company_employee` → `company` (успіх), `company_employee` → `solo_carrier` (exception), `self_employed` → `solo_carrier` (успіх), `DELETE` клієнта, поки на нього посилається водій (exception, `ON DELETE RESTRICT`) — усі відпрацювали коректно.

---

## 8.7. Real-time notification

`trg_after_delivery_status_notify`

Після INSERT або зміни `delivery_status` виконується:

```sql
pg_notify('delivery_status_channel', ...)
```

Payload містить:

- `delivery_id`;
- `order_id`;
- `delivery_status`;
- `updated_at`.

Це може використовувати backend для подальшої трансляції події через WebSocket.

> Це той самий "гачок", який просить ТЗ PM (розділ 8): "статуси через WebSockets у реальному часі" — бекенду не треба будувати окремий механізм опитування (`polling`), можна підписатись на `NOTIFY`.

---

## 8.8. Авто-блокування водія: низький рейтинг або скарги про шахрайство (додано 2026-09-23)

`fn_evaluate_driver_auto_block` + `trg_fraud_report_autoblock` / `trg_after_fraud_report_insert`, а також виклик `fn_evaluate_driver_auto_block` наприкінці `trg_update_driver_ratings` (§8, "SMART SKIP ENGINE").

**Бізнес-проблема (ТЗ PM §6.2, "Саморегуляція біржі"):** платформа працює без адміністратора-модератора в реальному часі, тож захист від шахраїв має спрацьовувати сам. ТЗ вимагає: якщо середній рейтинг водія падає нижче 3.2 ⭐, АБО 2 клієнти поскаржились через "Повідомити про шахрайство" — акаунт блокується автоматично.

**Правило:**

```text
ПІСЛЯ кожного оновлення avg_customer_rating (§8, п. 4)
   АБО кожного нового рядка в fraud_reports:

перевірити (тільки для водіїв зі status <> 'inactive'):
    IF avg_customer_rating < 3.20:
        status → 'inactive', blocked_at → now(), blocked_reason → 'auto_block: avg_customer_rating ... < 3.20'
    ELSE IF COUNT(fraud_reports для цього водія) >= 2:
        status → 'inactive', blocked_at → now(), blocked_reason → 'auto_block: fraud_reports_count ... >= 2'
```

**MVP-спрощення (свідоме, не вигадане "за замовчуванням"):** ТЗ буквально каже "2 клієнти **поспіль**" — тобто два останні незалежні випадки поспіль. Реалізовано простіше: рахується сумарна кількість скарг на водія за весь час, без відстеження послідовності "поспіль". Якщо точна семантика критична для бізнесу (наприклад, щоб одна давня й одна нова скарга через рік не блокували водія автоматично) — потрібне додаткове рішення (rolling-вікно за часом або прапорець "розглянуто").

**Відома межа (не вирішено зараз):** якщо адміністратор вручну розблокує водія (кнопка в Story 7, веб-панель), а показники (рейтинг/кількість скарг) ще не покращились — наступна ж подія (нова доставка або нова скарга) знову заблокує його автоматично. Потрібне окреме поле на кшталт "ручний override" з рішенням, як довго воно діє — свідомо не додано в цю ревізію.

**Чого тут НЕМАЄ і чому:** захист від зовнішніх атак (підбір паролів до акаунтів, сканування неіснуючих URL, DDoS) свідомо не входить у цю бізнес-БД. Причина: обсяг таких подій під час реальної атаки може сягати тисяч записів за секунду — писати їх у ту саму базу, де живуть замовлення й доставки, ризиковано для продуктивності основного бізнес-навантаження. Рекомендовано інфраструктурний рівень (rate-limiting / WAF / Cloudflare / nginx) — рішення власника продукту від 2026-09-23.

Технічно перевірено на живій PostgreSQL 16 + PostGIS: авто-блок через рейтинг (1 доставка з оцінкою 1.0 → `status='inactive'`), авто-блок через скарги (1 скарга → водій ще `available`; 2-га скарга → `status='inactive'`) — обидва сценарії відпрацювали коректно.

---

## 9. PostGIS spatial logic

## 9.1. `build_actual_route_geometry()`

Функція:

```sql
build_actual_route_geometry(p_delivery_id VARCHAR)
```

отримує GPS-точки доставки, сортує їх за `recorded_at` і будує `LineString` через:

```text
ST_MakeLine(...)
```

Результат — фактична траєкторія рейсу.

---

## 9.2. `is_route_deviated()`

Функція:

```sql
is_route_deviated(
    p_delivery_id VARCHAR,
    p_threshold_meters NUMERIC DEFAULT 2000
)
```

порівнює фактичні GPS-точки з плановою геометрією маршруту.

Для метричної відстані використовується:

```text
geometry → geography
```

За замовчуванням поріг становить:

```text
2000 метрів
```

Результат:

- `TRUE` — максимальне відхилення більше порога;
- `FALSE` — не перевищує поріг;
- `NULL` — недостатньо геометричних даних.

> Важливо: функція **повертає Boolean**, але сама по собі не записує `Driver_Route_Deviation` у `deliveries.incident_type`. Запис інциденту повинен виконувати application/service layer або окрема database procedure.

---

## 10. Analytical Views

## 10.1. `v_deliveries_analytics`

Операційний аналітичний view.

Розраховує:

```text
distance_deviation_km
distance_deviation_pct
```

Формула:

```text
actual_distance_km - planned_distance_km
```

та:

```text
((actual - planned) / planned) × 100
```

Використовується `NULLIF`, щоб уникнути division by zero.

---

## 10.2. `v_customer_order_tracking`

View для customer-facing tracking.

Об'єднує:

- order;
- matching status;
- origin/destination;
- pickup/delivery times;
- delivery status;
- actual start/end;
- delay.

`LEFT JOIN` дозволяє бачити замовлення навіть без створеної delivery.

---

## 10.3. `v_driver_net_income`

Розраховує агрегований net take-home водія.

Основні показники:

- `total_gross_payout_eur`;
- `corporate_operating_expenses_eur`;
- `private_driver_expenses_eur`;
- `net_driver_take_home_eur`.

Фактична формула SQL:

```text
SUM(driver_payout_eur) - SUM(cost_amount_eur)
```

При цьому view окремо показує корпоративні та приватні витрати.

> Примітка: SQL віднімає також private expenses у підсумковому `net_driver_take_home_eur`, хоча вони окремо класифікуються як private. Це потрібно враховувати на рівні бізнес-вимог до метрики.

---

## 10.4. `v_delivery_profitability`

Розраховує profitability кожної delivery.

Основні показники:

```text
gross_revenue_eur
direct_operating_costs_eur
driver_reward_eur
net_gross_profit_eur
gross_margin_pct
```

Формула:

```text
Net Gross Profit
=
Gross Revenue
- Direct Operating Costs
- Driver Reward
```

---

## 11. Smart Skip Engine

Trigger:

```text
trg_after_delivery_update
```

викликає:

```text
trg_update_driver_ratings()
```

### Крок 1 — перевірка можливості Smart Skip

Якщо одночасно:

- compliance = `100.00`;
- delay = 0 або NULL;
- `is_driver_liable = FALSE`;
- `incident_type = None`;
- customer rating відсутній;

функція завершується одразу.

Це зменшує кількість непотрібних aggregation queries для стандартних incident-free deliveries.

### Крок 2 — customer rating

Перераховуються:

```text
avg_customer_rating
total_reviews_count
```

на основі delivery records із rating.

### Крок 3 — 90-day metrics

Розраховуються:

- OTR — On-Time Rate;
- IFR — Incident-Free Rate;
- PODR — Proof-of-Delivery Rate.

Період:

```text
останні 90 днів
```

та лише deliveries зі статусом:

```text
delivered
```

### Крок 4 — weighted compliance score

Формула:

```text
Compliance
=
40% × OTR
+ 40% × IFR
+ 20% × PODR
```

Результат записується в:

```text
drivers.service_compliance_rate
```

---

## 12. Staging table для CSV

Створюється:

```text
staging_costs
```

як `UNLOGGED TABLE`, побудована на основі структури `costs`.

Призначення:

- масовий імпорт CSV;
- проміжна валідація / трансформація;
- подальше завантаження у production table `costs`.

`UNLOGGED` зменшує WAL overhead, але staging-дані не призначені для довгострокового надійного зберігання.

---

## 13. Test data isolation

У ключових таблицях передбачено:

```text
is_test BOOLEAN
```

Зокрема:

- `vehicles`;
- `drivers`;
- `orders`;
- `deliveries`;
- `costs`.

Це дозволяє відокремлювати тестові записи від production-потоку на рівні application queries та reporting.

> Сам факт наявності `is_test` не створює автоматичного фільтра: application/reporting layer повинен явно враховувати це поле.

---

## 14. Keyset pagination

Для замовлень передбачений індекс:

```text
idx_orders_client_tracking
```

на:

```text
(client_id, order_date DESC, order_id)
```

Рекомендований патерн:

```sql
SELECT *
FROM orders
WHERE client_id = $1
  AND (order_date, order_id) < ($2, $3)
ORDER BY order_date DESC, order_id DESC
LIMIT 20;
```

Це дозволяє уникати повільного `OFFSET` на великих наборах даних.

---

## 15. DevOps та infrastructure recommendations

SQL-файл містить рекомендації для backend infrastructure.

### Connection pooling

Рекомендовано:

```text
PgBouncer
```

у transaction mode для FastAPI backend.

### Statement timeout

Передбачено налаштування:

```sql
ALTER ROLE smartlog_app
SET statement_timeout = '15s';
```

### Idle transaction timeout

```sql
ALTER ROLE smartlog_app
SET idle_in_transaction_session_timeout = '30s';
```

Ці команди є рекомендаціями у коментарях SQL-файлу, а не виконуваними командами схеми.

---

## 16. Активація нової країни ЄС

Поточний seed активує `DE`.

Для нової країни потрібно:

1. Додати актуальну VAT rate.
2. Змінити `is_active` на `TRUE`.
3. Записати `activated_at`.

Приклад для Польщі:

```sql
INSERT INTO vat_rates (country_code, standard_rate_pct, valid_from)
VALUES ('PL', 23.00, CURRENT_DATE);

UPDATE supported_countries
SET is_active = TRUE,
    activated_at = CURRENT_TIMESTAMP
WHERE country_code = 'PL';
```

Після активації country triggers дозволять використовувати країну в client/order records.

---

## 17. Data integrity rules

Основні database-level constraints:

- позитивна маса та вантажопідйомність;
- позитивна кількість вантажу;
- позитивні planned distances;
- коректні delivery/order time windows;
- VAT = 0 при Reverse Charge;
- узгодженість Code 95;
- узгодженість ADR (`drivers.has_adr` ↔ `drivers.adr_expiry_date`);
- **узгодженість журналу верифікації клієнта** (`clients.is_verified` ↔ `verified_by`/`verified_at`) — додано 2026-09-16;
- `is_repair` тільки для maintenance;
- дозволені значення `cost_subtype`;
- `both_confirmed` тільки при двох підтвердженнях;
- активність країни;
- існування FOP driver при відповідному executor type;
- **відповідність `adr_required` замовлення й `has_adr` призначеного FOP-водія** — додано 2026-09-16.

---

## 18. Важливі технічні межі поточної реалізації

Цей розділ фіксує те, що **фактично робить поточний SQL**, без припущення про майбутню application logic.

### 18.1. Executor reference не є polymorphic FK

`orders.executor_id` — звичайний `VARCHAR(32)`.

Тому database schema не створює справжнього FK одночасно на `drivers` і `clients`.

Trigger перевіряє тільки:

```text
executor_type = fop_driver
```

для `drivers`.

### 18.2. Один order може мати кілька deliveries

У `deliveries` немає:

```sql
UNIQUE(order_id)
```

Тому БД не забороняє кілька delivery для одного order.

### 18.3. Route deviation не записує incident автоматично

`is_route_deviated()` тільки повертає Boolean.

Автоматичного:

```text
incident_type = Driver_Route_Deviation
```

у функції немає.

### 18.4. VAT logic — спрощена бізнес-модель

Поточний trigger використовує:

```text
origin_country <> destination_country
```

як умову Reverse Charge.

Реальні податкові правила можуть залежати від типу контрагента, VAT status та інших бізнес-умов. Ця документація описує саме логіку поточного SQL, а не юридичну податкову консультацію.

### 18.5. Timestamp `updated_at`

У таблицях є `updated_at`, але окремого універсального trigger, який автоматично змінює його при кожному UPDATE, у поточній схемі немає.

Application layer або окремий trigger повинен забезпечувати актуалізацію поля.

### 18.6. `vehicles.owner_client_id` не покриває всі авто (додано 2026-09-16)

Для авто штатних водіїв (`driver_type='company_employee'`), у яких немає окремого `client`-запису, що представляв би саму операційну компанію-власника автопарку, `owner_client_id` лишається `NULL`. Потрібно завести такий client-запис — рішення відкладено до наступної ітерації MVP.

### 18.7. Немає DB-рівневої перевірки протермінованості документів (додано 2026-09-16)

У `drivers` немає перевірки на рівні БД, чи не протермінувалися `driving_license_expiry_date`, `code_95_expiry_date`, `adr_expiry_date` відносно поточної дати — є лише CHECK-и на парність полів (наприклад, "якщо є `has_adr=TRUE`, то є і `adr_expiry_date`"), а не на актуальність самої дати. Це потрібно реалізовувати або окремим scheduled-job на backend, або окремою DB-перевіркою в наступній ітерації.

### 18.8. Немає довідника тарифів LKW-Maut (додано 2026-09-16)

Відсутня таблиця `toll_rates` (за `euro_emission_class` і `gross_vehicle_weight_kg`), потрібна для точного розрахунку дорожніх зборів у Німеччині.

---

## 19. Deployment sequence

DDL рекомендується виконувати як єдиний schema script:

```bash
psql -U postgres -d smartlog_db -f 001_smartlog_core_mvp_marketplace_schema.sql
```

Логічний порядок побудови:

```text
1. PostGIS extension
2. ENUM types
3. supported_countries
4. vat_rates
5. clients (з журналом верифікації)
6. vehicles (з owner_client_id)
7. drivers
8. routes
9. orders
10. deliveries
11. delivery_track_points
12. shipment_documents
13. costs
14. indexes
15. triggers/functions (включно з ADR compliance check)
16. spatial functions
17. analytical views
18. Smart Skip Engine
19. staging_costs
```

> Файл `01_smartlog_core_mvp_marketplace_schema.sql` є **єдиним актуальним скриптом створення бази даних** і повністю замінює `01_smartlog_core_mvp_marketplace_schema.sql`. Усі зміни, що раніше постачались окремим ALTER-патчем, тепер вбудовані напряму в `CREATE TABLE` — на новій, порожній базі достатньо виконати один цей файл, щоб одразу отримати фінальну структуру без застосування додаткових патчів.

---

## 20. Рекомендована роль компонентів системи

```text
                ┌──────────────────────┐
                │     Frontend / App   │
                └──────────┬───────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │ FastAPI Backend      │
                │ Business Logic       │
                │ Auth / API / WebSocket│
                └──────────┬───────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │ PostgreSQL + PostGIS │
                │                      │
                │ Core Data            │
                │ Constraints           │
                │ Triggers              │
                │ Spatial Functions     │
                │ Live Views            │
                └──────────┬───────────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
       PostgreSQL NOTIFY             S3 Storage
       delivery events              documents/e-POD
```

База даних відповідає за структуроване зберігання, referential integrity, частину бізнес-правил, spatial processing та аналітичні views.

Application layer відповідає за API, authentication/authorization, UI workflow, WebSocket delivery, складні marketplace processes та ті бізнес-правила, які не реалізовані в DDL.

---

## 21. Підсумок

`01_smartlog_core_mvp_marketplace_schema.sql` формує ядро SmartLog Europe навколо п'яти основних доменів:

1. **Marketplace** — `clients` (з журналом верифікації), `orders`, matching.
2. **Fleet & Drivers** — `drivers`, `vehicles` (з юридичним власником `owner_client_id`).
3. **Logistics Execution** — `routes`, `deliveries`, GPS tracking.
4. **Compliance & Documents** — VAT, ADR-відповідність виконавця, incidents, ratings, e-CMR/e-POD.
5. **Financial Analytics** — `costs` та profitability / income views.

Схема вже містить PostGIS, spatial indexes, triggers (включно з перевіркою ADR-відповідності виконавця), real-time `NOTIFY`, 90-day driver compliance calculation та live analytical views. Водночас частина orchestration logic залишається на backend-рівні, що важливо враховувати під час реалізації FastAPI сервісів і API.

Список відомих відкритих прогалин поточної ревізії — §18.6–§18.8.

---

## 22. Source of truth

Цей документ є технічною документацією до конкретного SQL-файлу:

```text
01_smartlog_core_mvp_marketplace_schema.sql
```

Цей файл повністю замінює собою попередню версію `01_smartlog_core_mvp_marketplace_schema.sql`.

Якщо SQL-схема змінюється, `DATABASE_SCHEMA.md` необхідно синхронізувати з DDL, щоб документація залишалася source-aligned.