// cmux-native-transcript: the read-only native transcript scene (RFD 0121, app-perf.md section 6, first PR).
//
// Rust owns the scene: the rows, their layout (done once per width), the viewport, the fling and the frame record.
// The app owns the CAMetalLayer, its render thread, the glyph atlas texture and the rich-row textures. Per display
// frame the render thread calls cmux_nt_frame, which writes the visible quads into a caller buffer; the app uploads
// them as one instance buffer and draws them in one pass.
//
// Glyphs: the scene allocates atlas slots (a shelf packer over an atlas of atlas_px x atlas_px pixels) and lists
// the glyphs it placed that the app has not rasterized yet (cmux_nt_take_raster_requests). The app rasterizes each
// (CoreText) into its slot, then calls cmux_nt_glyphs_ready. A glyph quad whose slot is not ready is still emitted;
// the app draws it once the slot is filled (one frame later at most).
//
// Rich rows (every tenth row of the fixture: a KaTeX block): the row's height is stored; its pixels are a texture
// the app makes off the render thread. The scene asks for textures ahead of the viewport
// (cmux_nt_take_texture_requests); a rich row on screen whose texture is not ready is a late texture, counted in
// the frame record. That count is THE number's second half: 0 late textures.
//
// Not thread safe: one scene is used by one thread at a time (the app's render thread, with input posted to it).

#ifndef CMUX_NATIVE_TRANSCRIPT_H
#define CMUX_NATIVE_TRANSCRIPT_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmuxNtScene CmuxNtScene;

// Quad kinds.
#define CMUX_NT_QUAD_GLYPH 0u   // uv is the atlas rect (0..1); color is the text color
#define CMUX_NT_QUAD_FILL 1u    // a solid rect (code block ground, rule); uv unused
#define CMUX_NT_QUAD_TEXTURE 2u // a rich row; texture_id names the app's texture; uv is the visible part of it

// One quad, in points from the top-left of the viewport. 48 bytes; laid out for a Metal instance buffer.
typedef struct CmuxNtQuad {
    float x, y, w, h;
    float u0, v0, u1, v1;
    uint32_t color;      // 0xRRGGBBAA
    uint32_t kind;       // CMUX_NT_QUAD_*
    uint32_t texture_id; // CMUX_NT_QUAD_TEXTURE only
    uint32_t _pad;
} CmuxNtQuad;

// The app's font metrics, in points. advances[i] is the advance of the printable ASCII byte 32 + i (95 entries);
// other characters use fallback_advance. mono_* are the code font's.
typedef struct CmuxNtMetrics {
    float advances[95];
    float fallback_advance;
    float line_height;
    float ascent;
    float glyph_w;      // the atlas cell of one text glyph, in points (scale applies to pixels)
    float glyph_h;
    float mono_advance;
    float mono_line_height;
    float scale;        // backing scale factor
    uint32_t atlas_px;  // atlas side in pixels
} CmuxNtMetrics;

// A glyph the app must rasterize: the character (a Unicode scalar), the font (0 text, 1 mono) and its atlas slot.
typedef struct CmuxNtRasterRequest {
    uint32_t scalar;
    uint32_t font;
    uint32_t slot_x, slot_y, slot_w, slot_h; // pixels
} CmuxNtRasterRequest;

// A rich row texture the app must make: its id, the row and its size in points.
typedef struct CmuxNtTextureRequest {
    uint32_t texture_id;
    uint32_t row;
    float w, h;
} CmuxNtTextureRequest;

typedef struct CmuxNtFrameInfo {
    double offset;          // scroll offset after this frame, points from the top of the document
    double content_height;
    uint32_t quads;         // written
    uint32_t quads_needed;  // all visible quads (> quads when the buffer was short)
    uint32_t first_row, last_row;
    uint32_t late_textures; // rich rows on screen this frame with no ready texture
    bool flinging;
    double build_us;        // this call's own time
} CmuxNtFrameInfo;

typedef struct CmuxNtStats {
    uint64_t frames;
    uint64_t late_texture_frames;  // frames with at least one late texture
    uint64_t late_textures;        // sum over frames
    double interval_p50_ms, interval_p95_ms, interval_max_ms; // between cmux_nt_frame `now` values while flinging
    double build_p50_us, build_p95_us, build_max_us;
    uint64_t intervals_over_8_33; // display intervals over 8.33 ms * 1.5 while flinging
} CmuxNtStats;

// The 3,000-row bench fixture (rows rows; every tenth a rich row of stored height; code blocks every seventh),
// laid out for the given width and metrics. Returns NULL on a bad argument.
CmuxNtScene *cmux_nt_scene_new_fixture(uint32_t rows, float width, float height, const CmuxNtMetrics *metrics);
void cmux_nt_scene_free(CmuxNtScene *scene);

// Viewport size in points. A width change lays the document out again (the only full layout).
void cmux_nt_set_viewport(CmuxNtScene *scene, float width, float height);
// Scroll to an offset (clamped); stops any fling.
void cmux_nt_scroll_to(CmuxNtScene *scene, double offset);
// Scroll by a wheel or trackpad delta (points; positive scrolls toward the end).
void cmux_nt_scroll_by(CmuxNtScene *scene, double delta);
// Start a fling at velocity points/s (positive toward the end) at time now (seconds, the display link's clock).
void cmux_nt_fling(CmuxNtScene *scene, double velocity, double now);

// Advance to time now and write the visible quads. Returns the number written.
uint32_t cmux_nt_frame(CmuxNtScene *scene, double now, CmuxNtQuad *out, uint32_t cap, CmuxNtFrameInfo *info);

// Glyph slots placed and not yet rasterized: writes up to cap, returns the count written; the rest stay queued.
uint32_t cmux_nt_take_raster_requests(CmuxNtScene *scene, CmuxNtRasterRequest *out, uint32_t cap);
// The app filled every slot it took so far.
void cmux_nt_glyphs_ready(CmuxNtScene *scene);
// Rich row textures to make (ahead of the viewport by prefetch_rows rows): writes up to cap, returns the count.
uint32_t cmux_nt_take_texture_requests(CmuxNtScene *scene, uint32_t prefetch_rows, CmuxNtTextureRequest *out,
                                       uint32_t cap);
// A texture is ready (or was released: ready = false, the scene will ask again when it nears the viewport).
void cmux_nt_texture_ready(CmuxNtScene *scene, uint32_t texture_id, bool ready);

// The frame record since the scene was made or the last reset; reset clears it.
void cmux_nt_stats(const CmuxNtScene *scene, CmuxNtStats *out);
void cmux_nt_stats_reset(CmuxNtScene *scene);

#ifdef __cplusplus
}
#endif

#endif
