// HMAC-SHA256 helper for ESP32 (mbedtls based)
// ESPHome esphome.includes 経由で取り込み。
#pragma once

#include <string>
#include "mbedtls/md.h"

inline std::string yakiimo_hmac_sha256_hex(const std::string& secret, const std::string& message) {
  unsigned char hmac_out[32];
  const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);

  mbedtls_md_context_t ctx;
  mbedtls_md_init(&ctx);
  mbedtls_md_setup(&ctx, info, 1);  // 1: HMAC モード
  mbedtls_md_hmac_starts(&ctx, reinterpret_cast<const unsigned char*>(secret.data()), secret.size());
  mbedtls_md_hmac_update(&ctx, reinterpret_cast<const unsigned char*>(message.data()), message.size());
  mbedtls_md_hmac_finish(&ctx, hmac_out);
  mbedtls_md_free(&ctx);

  static const char hex_chars[] = "0123456789abcdef";
  std::string out;
  out.reserve(64);
  for (int i = 0; i < 32; i++) {
    out.push_back(hex_chars[(hmac_out[i] >> 4) & 0x0f]);
    out.push_back(hex_chars[hmac_out[i] & 0x0f]);
  }
  return out;
}
