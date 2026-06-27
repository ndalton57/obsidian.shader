/*
--------------------------------------------------------------------------------

  Tachyon Shader

  program/c14_c18_bloom_upsample.fsh
  Progressively upsample bloom tiles
  You must define BLOOM_TILE_INDEX before including this file

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

#define bloom_tile_scale(i) 0.5 * exp2(-(i))
#define bloom_tile_offset(i) \
    vec2(1.0 - exp2(-(i)), float((i) & 1) * (1.0 - 0.5 * exp2(-(i))))

layout(location = 0) out vec3 bloom_tile;

/* RENDERTARGETS: 0 */

in vec2 uv;

uniform vec2 view_pixel_size;

const float tile_scale = bloom_tile_scale(BLOOM_TILE_INDEX);
const vec2 tile_offset = bloom_tile_offset(BLOOM_TILE_INDEX);

const float src_tile_scale = bloom_tile_scale(BLOOM_TILE_INDEX + 1);
const vec2 src_tile_offset = bloom_tile_offset(BLOOM_TILE_INDEX + 1);

uniform sampler2D colortex0;
#define SRC_SAMPLER colortex0

#include "/include/utility/bicubic.glsl"

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);

    // Pad relative to the SOURCE tile scale: the source tile is half the size
    // of this one, so a destination-scale pad leaves only a 1.5px margin
    // inside the source — not enough for the bicubic filter's 2px reach, and
    // marginal taps into the neighbouring tile turn extreme HDR content into
    // displaced ghost copies on screen.
    vec2 pad_amount = 3.0 * view_pixel_size * rcp(src_tile_scale);
    vec2 uv_src = clamp(uv, pad_amount, 1.0 - pad_amount) * src_tile_scale
        + src_tile_offset;

    const float src_weight = mix(0.25, 0.90, 0.5 * BLOOM_SPREAD);
    bloom_tile = texelFetch(SRC_SAMPLER, texel, 0).rgb * (1.0 - src_weight); // Destination tile.
    bloom_tile += BLOOM_UPSAMPLING_FILTER(SRC_SAMPLER, uv_src).rgb * src_weight; // Source tile.
}

