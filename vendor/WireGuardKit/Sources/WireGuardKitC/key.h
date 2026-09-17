/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2015-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

#ifndef KEY_H
#define KEY_H

#include <stdbool.h>
#include <stdint.h>

#define WG_KEY_LEN (32)
#define WG_KEY_LEN_BASE64 (45)
#define WG_KEY_LEN_HEX (65)

void key_to_base64(char base64[static WG_KEY_LEN_BASE64], const uint8_t key[static WG_KEY_LEN]);
bool key_from_base64(uint8_t key[static WG_KEY_LEN], const char *base64);

void key_to_hex(char hex[static WG_KEY_LEN_HEX], const uint8_t key[static WG_KEY_LEN]);
bool key_from_hex(uint8_t key[static WG_KEY_LEN], const char *hex);

bool key_eq(const uint8_t key1[static WG_KEY_LEN], const uint8_t key2[static WG_KEY_LEN]);

#endif
