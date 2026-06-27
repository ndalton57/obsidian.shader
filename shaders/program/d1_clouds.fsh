/*
--------------------------------------------------------------------------------

  Tachyon Shader

  program/d1_clouds:
  Render clouds and aurora

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(location = 0) out vec4 clouds;
layout(location = 1) out vec2 clouds_data;

/* RENDERTARGETS: 9,10 */

in vec2 uv;

#if defined WORLD_OVERWORLD
flat in vec3 sun_color;
flat in vec3 moon_color;
flat in vec3 sky_color;

flat in float aurora_amount;
flat in mat2x3 aurora_colors;
#endif

// ------------
//   Uniforms
// ------------

uniform sampler2D cloud_noisetex; // cloud shape noise (customTexture)
#define CLOUD_NOISETEX cloud_noisetex

uniform sampler2D colortex8; // cloud shadow map

uniform sampler3D depthtex0; // atmospheric scattering LUT
uniform sampler2D depthtex1;

uniform sampler2D noisetex;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

uniform float near;
uniform float far;

uniform int worldTime;
uniform int worldDay;
uniform int moonPhase;
uniform float sunAngle;

uniform int frameCounter;
uniform float frameTimeCounter;

uniform int isEyeInWater;
uniform float eyeAltitude;
uniform float rainStrength;
uniform float wetness;

uniform vec3 light_dir;
uniform vec3 sun_dir;
uniform vec3 moon_dir;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec2 taa_offset;

uniform float world_age;
uniform float cloud_time;

uniform float time_sunrise;
uniform float time_noon;
uniform float time_sunset;
uniform float time_midnight;

uniform float biome_cave;
uniform float biome_temperate;
uniform float biome_arid;
uniform float biome_snowy;
uniform float biome_taiga;
uniform float biome_jungle;
uniform float biome_swamp;
uniform float biome_may_rain;
uniform float biome_may_snow;
uniform float biome_temperature;
uniform float biome_humidity;

// ------------
//   Includes
// ------------

#define ATMOSPHERE_SCATTERING_LUT depthtex0
#define MIE_PHASE_CLAMP

#if defined WORLD_OVERWORLD
#include "/include/sky/atmosphere.glsl"
#include "/include/sky/aurora.glsl"
#include "/include/sky/clouds.glsl"
#endif

#include "/include/misc/lod_mod_support.glsl"
#include "/include/utility/checkerboard.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/space_conversion.glsl"

const int checkerboard_area
    = CLOUDS_TEMPORAL_UPSCALING * CLOUDS_TEMPORAL_UPSCALING;

float depth_max_4x4(sampler2D depth_sampler, float scale) {
    vec4 depth_samples_0 = textureGather(
        depth_sampler,
        uv * scale + vec2(2.0 * view_pixel_size.x, 2.0 * view_pixel_size.y)
    );
    vec4 depth_samples_1 = textureGather(
        depth_sampler,
        uv * scale + vec2(-2.0 * view_pixel_size.x, 2.0 * view_pixel_size.y)
    );
    vec4 depth_samples_2 = textureGather(
        depth_sampler,
        uv * scale + vec2(2.0 * view_pixel_size.x, -2.0 * view_pixel_size.y)
    );
    vec4 depth_samples_3 = textureGather(
        depth_sampler,
        uv * scale + vec2(-2.0 * view_pixel_size.x, -2.0 * view_pixel_size.y)
    );

    return max(
        max(max_of(depth_samples_0), max_of(depth_samples_1)),
        max(max_of(depth_samples_2), max_of(depth_samples_3))
    );
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);

    clouds = vec4(0.0, 0.0, 0.0, 1.0);

#if defined WORLD_OVERWORLD
#if CLOUDS_TEMPORAL_UPSCALING == 2
    // Half-res-every-frame mode (the same per-frame
    // budget spent differently): every quarter-area texel re-marches each frame from the centre
    // of its 2x2 block with a fresh dither realization — a complete,
    // temporally stable low-res image, instead of sparse full-res samples
    // cycled through the checkerboard. d2 then acts as a plain temporal
    // average and nothing on screen ever waits for history to fill in.
    ivec2 checkerboard_pos = CLOUDS_TEMPORAL_UPSCALING * texel + ivec2(1);
#else
    ivec2 checkerboard_pos = CLOUDS_TEMPORAL_UPSCALING * texel
        + clouds_checkerboard_offsets[frameCounter % checkerboard_area];
#endif

    vec2 new_uv = vec2(checkerboard_pos) / vec2(view_res)
        * rcp(float(taau_render_scale));

    // Get maximum depth from area covered by this fragment
    float depth_max = depth_max_4x4(depthtex1, taau_render_scale);

    vec3 screen_pos = vec3(new_uv, depth_max);
    vec3 view_pos = screen_to_view_space(screen_pos, false);

    // LoD terrain support
#ifdef LOD_MOD_ACTIVE
    float depth_lod = depth_max_4x4(lod_depth_tex, lod_depth_tex_scale);
    bool is_lod = is_lod_terrain(depth_max, depth_lod);

    if (is_lod) {
        screen_pos = vec3(new_uv, depth_lod);
        view_pos = screen_to_view_space(screen_pos, false, true);
    }
#else
    const bool is_lod = false;
#endif

    vec3 ray_dir = mat3(gbufferModelViewInverse) * normalize(view_pos);

    // Real-world blocks; the cloud field marches in world units
    float distance_to_terrain
        = (depth_max == 1.0 && !is_lod) ? -1.0 : length(view_pos);

    float dither = texelFetch(noisetex, ivec2(checkerboard_pos & 511), 0).b;
#if CLOUDS_TEMPORAL_UPSCALING == 2
    // fresh realization every frame — the texel is re-marched every frame
    dither = r1(frameCounter, dither);
#else
    dither = r1(frameCounter / checkerboard_area, dither);
#endif

#ifndef BLOCKY_CLOUDS
    CloudsResult result = draw_clouds(
        ray_dir,
        distance_to_terrain,
        dither
    );

    clouds.xyz = result.scattering.xyz;
    clouds.w = result.transmittance;
    clouds_data.x = result.apparent_distance;
    clouds_data.y = result.scattering.w;
#else
    clouds = vec4(0.0, 0.0, 0.0, 1.0);
    clouds_data.x = 1e6;
    clouds_data.y = 0.0;
#endif

    // Aurora

    clouds.xyz += draw_aurora(ray_dir, dither) * clouds.w;
#endif
}
