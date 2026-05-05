// yakiimo-temp-monitor / ESP32 firmware
//
// 役割:
//   1秒ごとに 4ch MAX31855(熱電対) + 1× BME280(環境) を読み、
//   5秒分(=25行)を1リクエストにまとめて Supabase REST API へ POST する。
//   WiFi 切断時は最大 6分分(1800行)を RAM のリングバッファに保持し、復旧時に flush。
//   全滅時はシリアル出力で生データを残す(USB 接続中ならホスト PC に届く)。
//
// チャンネル割当(plan に基づく):
//   CH0 (CS GPIO5)  → potato_internal  (やきいも内部)
//   CH1 (CS GPIO15) → potato_surface   (やきいも表面)
//   CH2 (CS GPIO26) → kiln_ambient     (釜の雰囲気温度)
//   CH3 (CS GPIO27) → stone_surface    (石の表面温度)
//   I2C BME280      → env              (屋外の気温・湿度・気圧)

#include <Arduino.h>
#include <SPI.h>
#include <Wire.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <Adafruit_MAX31855.h>
#include <Adafruit_BME280.h>
#include <ArduinoJson.h>
#include "secrets.h"

// ---- ピン定義 ----
static const int PIN_SCK  = 18;
static const int PIN_MISO = 19;
static const int PIN_CS[4] = { 5, 15, 26, 27 };

// BME280 を 3V3 側 (J2 列) に物理配置するため、I2C ピンも 3V3 側 GPIO32/33 を使用
static const int PIN_SDA = 32;
static const int PIN_SCL = 33;

// ---- チャンネル名 ----
static const char* CHANNEL_NAMES[4] = {
  "potato_internal",
  "potato_surface",
  "kiln_ambient",
  "stone_surface",
};
static const char* ENV_CHANNEL = "env";

// ---- センサー ----
Adafruit_MAX31855 thermocouples[4] = {
  Adafruit_MAX31855(PIN_SCK, PIN_CS[0], PIN_MISO),
  Adafruit_MAX31855(PIN_SCK, PIN_CS[1], PIN_MISO),
  Adafruit_MAX31855(PIN_SCK, PIN_CS[2], PIN_MISO),
  Adafruit_MAX31855(PIN_SCK, PIN_CS[3], PIN_MISO),
};
Adafruit_BME280 bme;
bool bmeAvailable = false;

// ---- リングバッファ ----
// 1サンプル = 5チャンネル分の行を保持する構造体
struct Sample {
  uint32_t epoch_sec;       // measured_at (UTC epoch sec)
  float    tc_c[4];         // 熱電対 4ch
  uint8_t  tc_fault[4];     // MAX31855 のフォルトビット (raw 用)
  bool     tc_valid[4];     // 値が読めたか
  float    env_temp_c;
  float    env_humidity;
  float    env_pressure_hpa;
  bool     env_valid;
};

// 6分分 = 360 秒のサンプル(各サンプルは 5ch を持つ)
// メモリ余裕を見て少し大きめに
static const size_t BUFFER_CAP = 400;
Sample ringBuf[BUFFER_CAP];
size_t bufHead = 0;   // 次に書き込む位置
size_t bufCount = 0;  // 現在のサンプル数

// ---- バッチ送信間隔 ----
static const uint32_t SAMPLE_INTERVAL_MS = 1000;   // 1秒/サンプル
static const size_t   BATCH_SIZE         = 5;     // 5サンプルでまとめて POST(=25行)
static const uint32_t HTTP_TIMEOUT_MS    = 8000;
static const uint32_t WIFI_RETRY_INTERVAL_MS = 10000; // WiFi 切断時の再接続試行間隔

// ---- 状態 ----
uint32_t lastSampleMs = 0;
uint32_t lastWifiTryMs = 0;
uint32_t bootEpoch = 0;     // boot 時の epoch(NTP同期後)

// ---- ユーティリティ ----
void connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) return;
  Serial.printf("[WiFi] connecting to %s ...\n", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 15000) {
    delay(250);
    Serial.print(".");
  }
  Serial.println();
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("[WiFi] OK  IP=%s  RSSI=%d\n",
                  WiFi.localIP().toString().c_str(), WiFi.RSSI());
  } else {
    Serial.println("[WiFi] FAILED (will retry)");
  }
}

bool syncTimeOnce() {
  // NTP 同期(JST に合わせず UTC のまま使う。Supabase 側で TIMESTAMPTZ なので問題なし)
  configTime(0, 0, "pool.ntp.org", "time.google.com");
  Serial.print("[NTP] syncing");
  for (int i = 0; i < 30; i++) {
    time_t now = time(nullptr);
    if (now > 1700000000) {
      bootEpoch = now - (millis() / 1000);
      Serial.printf(" OK (epoch=%lu)\n", (unsigned long)now);
      return true;
    }
    delay(500);
    Serial.print(".");
  }
  Serial.println(" FAILED");
  return false;
}

uint32_t nowEpoch() {
  time_t t = time(nullptr);
  if (t > 1700000000) return (uint32_t)t;
  // NTP 未同期の fallback: bootEpoch + millis (粗い)
  return bootEpoch + (uint32_t)(millis() / 1000);
}

// ISO 8601 (RFC 3339) にエンコード: '2026-05-03T01:23:45Z'
String epochToIso(uint32_t epoch) {
  time_t t = (time_t)epoch;
  struct tm tmv;
  gmtime_r(&t, &tmv);
  char buf[32];
  strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tmv);
  return String(buf);
}

void readSample(Sample& s) {
  s.epoch_sec = nowEpoch();

  for (int i = 0; i < 4; i++) {
    double c = thermocouples[i].readCelsius();
    uint8_t fault = thermocouples[i].readError();
    s.tc_fault[i] = fault;
    if (isnan(c) || fault != 0) {
      s.tc_c[i] = NAN;
      s.tc_valid[i] = false;
    } else {
      s.tc_c[i] = (float)c;
      s.tc_valid[i] = true;
    }
  }

  if (bmeAvailable) {
    s.env_temp_c       = bme.readTemperature();
    s.env_humidity     = bme.readHumidity();
    s.env_pressure_hpa = bme.readPressure() / 100.0f;
    s.env_valid = !isnan(s.env_temp_c);
  } else {
    s.env_valid = false;
  }
}

void pushSample(const Sample& s) {
  ringBuf[bufHead] = s;
  bufHead = (bufHead + 1) % BUFFER_CAP;
  if (bufCount < BUFFER_CAP) bufCount++;
}

// バッファの先頭(古い順)から n 件参照する
size_t bufTailIndex(size_t offset) {
  // bufHead は次に書く場所。最も古いサンプルは bufHead - bufCount。
  size_t tail = (bufHead + BUFFER_CAP - bufCount) % BUFFER_CAP;
  return (tail + offset) % BUFFER_CAP;
}

// バッファの先頭から n 件を捨てる(POST 成功後に呼ぶ)
void bufConsume(size_t n) {
  if (n > bufCount) n = bufCount;
  bufCount -= n;
  // bufHead は変えない。tail だけが進む(計算上、bufCount の減少で表現)
}

// JSON ボディを構築: バッファ先頭から最大 BATCH_SIZE 件を取り出して 5ch ずつ展開
// (1 sample → 4 thermocouple rows + (env_valid なら) 1 env row = 最大 5行/sample)
size_t buildBatchJson(String& body, size_t maxSamples) {
  if (bufCount == 0) { body = "[]"; return 0; }

  size_t take = bufCount < maxSamples ? bufCount : maxSamples;

  // ArduinoJson v7: JsonDocument(自動拡張)
  JsonDocument doc;
  JsonArray arr = doc.to<JsonArray>();

  for (size_t i = 0; i < take; i++) {
    const Sample& s = ringBuf[bufTailIndex(i)];
    String iso = epochToIso(s.epoch_sec);

    for (int ch = 0; ch < 4; ch++) {
      JsonObject row = arr.add<JsonObject>();
      row["measured_at"] = iso;
      row["device_id"]   = DEVICE_ID;
      row["session_id"]  = SESSION_ID;
      row["channel"]     = CHANNEL_NAMES[ch];
      if (s.tc_valid[ch]) {
        row["temp_c"] = s.tc_c[ch];
      } else {
        row["temp_c"] = nullptr;
      }
      JsonObject raw = row["raw"].to<JsonObject>();
      raw["fault"] = s.tc_fault[ch];
      raw["valid"] = s.tc_valid[ch];
    }

    if (s.env_valid) {
      JsonObject row = arr.add<JsonObject>();
      row["measured_at"]   = iso;
      row["device_id"]     = DEVICE_ID;
      row["session_id"]    = SESSION_ID;
      row["channel"]       = ENV_CHANNEL;
      row["temp_c"]        = s.env_temp_c;
      row["humidity_pct"]  = s.env_humidity;
      row["pressure_hpa"]  = s.env_pressure_hpa;
    }
  }

  body = "";
  serializeJson(doc, body);
  return take;
}

bool postToSupabase(const String& body) {
  if (WiFi.status() != WL_CONNECTED) return false;

  WiFiClientSecure client;
  client.setInsecure();  // Supabase の証明書検証を省略(ESP32 では証明書管理が面倒なので。家庭利用前提)

  HTTPClient http;
  String url = String(SUPABASE_URL) + "/rest/v1/yakiimo_temp_logs";
  if (!http.begin(client, url)) {
    Serial.println("[HTTP] begin failed");
    return false;
  }

  http.setTimeout(HTTP_TIMEOUT_MS);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  http.addHeader("Prefer", "return=minimal");

  int code = http.POST(body);
  bool ok = (code == 201 || code == 200 || code == 204);
  if (!ok) {
    Serial.printf("[HTTP] POST failed: code=%d  body_head=%.120s\n",
                  code, body.c_str());
    String resp = http.getString();
    if (resp.length()) Serial.printf("[HTTP] resp=%.200s\n", resp.c_str());
  }
  http.end();
  return ok;
}

// バッファの全件を順次 POST(WiFi復旧時の flush)
void flushBufferIfPossible() {
  while (bufCount > 0 && WiFi.status() == WL_CONNECTED) {
    String body;
    size_t taken = buildBatchJson(body, BATCH_SIZE);
    if (taken == 0) break;
    bool ok = postToSupabase(body);
    if (!ok) break;  // 失敗したら次のループで再試行
    bufConsume(taken);
  }
}

// シリアルに生データを出す(全滅時の最後の砦)
void dumpSampleToSerial(const Sample& s) {
  Serial.printf("[SAMPLE] ts=%lu", (unsigned long)s.epoch_sec);
  for (int ch = 0; ch < 4; ch++) {
    if (s.tc_valid[ch]) {
      Serial.printf("  %s=%.2f", CHANNEL_NAMES[ch], s.tc_c[ch]);
    } else {
      Serial.printf("  %s=NaN(fault=0x%02X)", CHANNEL_NAMES[ch], s.tc_fault[ch]);
    }
  }
  if (s.env_valid) {
    Serial.printf("  env=%.2f/%.1f%%/%.1fhPa",
                  s.env_temp_c, s.env_humidity, s.env_pressure_hpa);
  }
  Serial.println();
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("=========================================");
  Serial.println("yakiimo-temp-monitor ESP32 firmware boot");
  Serial.printf("  device_id=%s  session_id=%s\n", DEVICE_ID, SESSION_ID);
  Serial.println("=========================================");

  // SPI(MAX31855)
  SPI.begin(PIN_SCK, PIN_MISO, -1);
  for (int i = 0; i < 4; i++) {
    pinMode(PIN_CS[i], OUTPUT);
    digitalWrite(PIN_CS[i], HIGH);
    if (thermocouples[i].begin()) {
      Serial.printf("[MAX31855 #%d] OK (CS=GPIO%d)\n", i, PIN_CS[i]);
    } else {
      Serial.printf("[MAX31855 #%d] init failed (CS=GPIO%d)\n", i, PIN_CS[i]);
    }
  }

  // I2C(BME280)
  Wire.begin(PIN_SDA, PIN_SCL);
  if (bme.begin(0x76) || bme.begin(0x77)) {
    bmeAvailable = true;
    Serial.println("[BME280] OK");
  } else {
    bmeAvailable = false;
    Serial.println("[BME280] not found (env channel disabled)");
  }

  connectWiFi();
  syncTimeOnce();
}

void loop() {
  uint32_t now = millis();

  // 1. WiFi が切れていたら定期的に再接続を試行
  if (WiFi.status() != WL_CONNECTED && now - lastWifiTryMs > WIFI_RETRY_INTERVAL_MS) {
    lastWifiTryMs = now;
    connectWiFi();
    if (WiFi.status() == WL_CONNECTED && bootEpoch == 0) {
      syncTimeOnce();
    }
  }

  // 2. 1秒に1回サンプリング
  if (now - lastSampleMs >= SAMPLE_INTERVAL_MS) {
    lastSampleMs = now;
    Sample s;
    readSample(s);
    pushSample(s);
    dumpSampleToSerial(s);

    // 3. BATCH_SIZE 溜まったら POST
    if (bufCount >= BATCH_SIZE && WiFi.status() == WL_CONNECTED) {
      String body;
      size_t taken = buildBatchJson(body, BATCH_SIZE);
      if (taken > 0 && postToSupabase(body)) {
        bufConsume(taken);
      }
    }

    // 4. WiFi 復旧後はバッファに残っている分を flush
    if (WiFi.status() == WL_CONNECTED && bufCount > BATCH_SIZE) {
      flushBufferIfPossible();
    }

    // 5. バッファが満杯近くなったらシリアルに警告
    if (bufCount >= BUFFER_CAP - 10) {
      Serial.printf("[WARN] buffer near full (%u/%u). Oldest samples will be overwritten.\n",
                    (unsigned)bufCount, (unsigned)BUFFER_CAP);
    }
  }
}
