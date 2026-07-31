// Copyright 2026 manaflow-ai. All rights reserved.
//
// cmux_profile.cc -- stub implementation of the profile / cookie /
// data-removal portion of the cmux embedder C ABI. Lands at
// src/cmux/embedder/cmux_profile.cc in the fork. Real implementation
// wraps content::BrowserContext + a CookieManager from
// //services/network/public; the stubs here return CMUX_E_NATIVE.

#include "cmux/embedder/cmux_browser.h"

extern "C" {

// Defined in cmux_session.cc. Sets the per-session last-error string
// readable via cmux_session_last_error_string.
void cmux_internal_set_last_error(const char* msg);

cmux_status_t cmux_profile_open(cmux_session_t* /*session*/,
                                const char* /*name_or_null*/,
                                cmux_profile_t** /*out_profile*/) {
  cmux_internal_set_last_error("cmux_profile_open: stub");
  return CMUX_E_NATIVE;
}

void cmux_profile_close(cmux_profile_t* /*profile*/) {
  // No-op in the stub.
}

cmux_status_t cmux_profile_get_cookies(cmux_profile_t* /*profile*/,
                                       const char* /*url_or_null*/,
                                       void* /*userdata*/,
                                       cmux_cookie_visitor /*visitor*/) {
  cmux_internal_set_last_error("cmux_profile_get_cookies: stub");
  return CMUX_E_NATIVE;
}

cmux_status_t cmux_profile_set_cookie(cmux_profile_t* /*profile*/,
                                      const char* /*name*/,
                                      const char* /*value*/,
                                      const char* /*domain*/,
                                      const char* /*path*/,
                                      int64_t /*expires_unix_ms*/,
                                      bool /*secure*/,
                                      bool /*http_only*/) {
  cmux_internal_set_last_error("cmux_profile_set_cookie: stub");
  return CMUX_E_NATIVE;
}

cmux_status_t cmux_profile_delete_cookie(cmux_profile_t* /*profile*/,
                                         const char* /*name*/,
                                         const char* /*domain*/,
                                         const char* /*path*/) {
  cmux_internal_set_last_error("cmux_profile_delete_cookie: stub");
  return CMUX_E_NATIVE;
}

cmux_status_t cmux_profile_remove_data(cmux_profile_t* /*profile*/,
                                       cmux_data_type_mask_t /*mask*/,
                                       int64_t /*since_unix_ms*/) {
  cmux_internal_set_last_error("cmux_profile_remove_data: stub");
  return CMUX_E_NATIVE;
}

}  // extern "C"
