/*
--------------------------------------------------------------------------------

  Tachyon Shader (a fork of SixthSurge's Photon Shaders)

  program/d3_ao:
  Calculate ambient occlusion

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(
    location = 0
) out vec4 ambient; // ao, ambient SSS, octahedrally encoded bent normal
layout(location = 1) out vec2 ambient_history_data; // depth, pixel age

/* RENDERTARGETS: 6,14 */

in vec2 uv;

// ------------
//   Uniforms
// ------------

uniform sampler2D noisetex;

uniform sampler2D colortex1; // gbuffer 0
uniform sampler2D colortex2; // gbuffer 1
uniform sampler2D colortex6; // ambient lighting data
uniform sampler2D colortex14; // ambient lighting history data

uniform sampler2D depthtex1;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

uniform float near;
uniform float far;
uniform float eyeAltitude;

uniform int frameCounter;

uniform vec3 light_dir;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec2 taa_offset;
uniform vec2 clouds_offset;

uniform bool world_age_changed;

// ------------
//   Includes
// ------------

#define TEMPORAL_REPROJECTION
#include "/include/misc/lod_mod_support.glsl"
#include "/include/utility/bicubic.glsl"
#include "/include/utility/dithering.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/slerp.glsl"
#include "/include/utility/space_conversion.glsl"

#if SHADER_AO == SHADER_AO_SSAO
#include "/include/lighting/ao/ssao.glsl"
#endif

#if SHADER_AO == SHADER_AO_GTAO
#include "/include/lighting/ao/gtao.glsl"
#endif

const float ao_render_scale = 0.5;

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    ivec2 view_texel
        = ivec2(gl_FragCoord.xy * (taau_render_scale / ao_render_scale));

    if (clamp(view_texel, ivec2(0), ivec2(view_res)) != view_texel) {
        return;
    }

    float depth = texelFetch(combined_depth_tex, view_texel, 0).x;

#ifndef NORMAL_MAPPING
    vec4 gbuffer_data = texelFetch(colortex1, view_texel, 0);
#else
    vec4 gbuffer_data = texelFetch(colortex2, view_texel, 0);
#endif
    vec2 dither = vec2(
        texelFetch(noisetex, texel & 511, 0).b,
        texelFetch(noisetex, (texel + 249) & 511, 0).b
    );

    // Distant Horizons support

#ifdef LOD_MOD_ACTIVE
    float depth_mc = texelFetch(depthtex1, view_texel, 0).x;
    float depth_lod = texelFetch(lod_depth_tex, view_texel, 0).x;
    bool is_lod = is_lod_terrain(depth_mc, depth_lod);
#else
#define depth_mc depth
    const bool is_lod = false;
#endif

    bool is_hand;
    fix_hand_depth(depth_mc, is_hand);

    vec3 screen_pos = vec3(uv, depth);
    vec3 view_pos = screen_to_view_space(
        combined_projection_matrix_inverse,
        screen_pos,
        true
    );
    vec3 scene_pos = view_to_scene_space(view_pos);

    vec3 previous_screen_pos = reproject_scene_space(scene_pos, false, false);

    if (depth == 1.0) {
        ambient = vec4(1.0, 0.0, 0.0, 0.0);
        ambient_history_data = vec2(0.0);
        return;
    }

#ifdef NORMAL_MAPPING
    vec3 world_normal = decode_unit_vector(gbuffer_data.xy);
#else
    vec3 world_normal = decode_unit_vector(unpack_unorm_2x8(gbuffer_data.z));
#endif

#ifdef LOD_MOD_ACTIVE
    if (is_lod) {
        // The LoD gbuffer normal decodes broken (see d4) - rebuild the face
        // normal from depth taps a couple of pixels apart instead (matching
        // d4: wide taps suppress per-pixel moire striping, picking the
        // depth-closer neighbour per axis avoids smearing over silhouettes)
        const int taps_radius = 2;
        ivec2 max_texel = ivec2(view_res * taau_render_scale) - 1;
        ivec2 texel_x0 = clamp(view_texel - ivec2(taps_radius, 0), ivec2(0), max_texel);
        ivec2 texel_x1 = clamp(view_texel + ivec2(taps_radius, 0), ivec2(0), max_texel);
        ivec2 texel_y0 = clamp(view_texel - ivec2(0, taps_radius), ivec2(0), max_texel);
        ivec2 texel_y1 = clamp(view_texel + ivec2(0, taps_radius), ivec2(0), max_texel);

        float depth_x0 = texelFetch(combined_depth_tex, texel_x0, 0).x;
        float depth_x1 = texelFetch(combined_depth_tex, texel_x1, 0).x;
        float depth_y0 = texelFetch(combined_depth_tex, texel_y0, 0).x;
        float depth_y1 = texelFetch(combined_depth_tex, texel_y1, 0).x;

        bool pick_x1 = abs(depth_x1 - depth) < abs(depth_x0 - depth);
        bool pick_y1 = abs(depth_y1 - depth) < abs(depth_y0 - depth);

        vec2 uv_x = uv
            + vec2((pick_x1 ? texel_x1 : texel_x0) - view_texel)
                * view_pixel_size * rcp(taau_render_scale);
        vec2 uv_y = uv
            + vec2((pick_y1 ? texel_y1 : texel_y0) - view_texel)
                * view_pixel_size * rcp(taau_render_scale);

        vec3 position_x = screen_to_view_space(
            combined_projection_matrix_inverse,
            vec3(uv_x, pick_x1 ? depth_x1 : depth_x0),
            true
        );
        vec3 position_y = screen_to_view_space(
            combined_projection_matrix_inverse,
            vec3(uv_y, pick_y1 ? depth_y1 : depth_y0),
            true
        );

        vec3 delta_x = pick_x1 ? position_x - view_pos : view_pos - position_x;
        vec3 delta_y = pick_y1 ? position_y - view_pos : view_pos - position_y;

        vec3 lod_normal_view = normalize(cross(delta_x, delta_y));
        lod_normal_view = dot(lod_normal_view, view_pos) > 0.0
            ? -lod_normal_view
            : lod_normal_view;
        world_normal = mat3(gbufferModelViewInverse) * lod_normal_view;
    }
#endif

    vec3 view_normal = mat3(gbufferModelView) * world_normal;

    dither = r2(frameCounter, dither);

    // Calculate AO

    vec2 ao;
    vec3 bent_normal;

#if SHADER_AO == SHADER_AO_NONE
    ao = vec2(1.0, 0.0);
    bent_normal = view_normal;
#elif SHADER_AO == SHADER_AO_SSAO
    ao.x = compute_ssao(screen_pos, view_pos, view_normal, dither);
    ao.y = 0.0;
    bent_normal = view_normal;
#elif SHADER_AO == SHADER_AO_GTAO
    ao = compute_gtao(
        screen_pos,
        view_pos,
        view_normal,
        dither,
        is_lod,
        bent_normal
    );
#endif

    // Temporal accumulation

    const float max_accumulated_frames = 10.0;
    const float depth_rejection_strength = 16.0;
    const float offcenter_rejection_strength = 0.25;

    vec4 history = max0(
        catmull_rom_filter_fast(colortex6, previous_screen_pos.xy, 0.65)
    );
    vec2 history_data = max0(texture(colortex14, previous_screen_pos.xy).xy);

    if (clamp01(previous_screen_pos.xy) == previous_screen_pos.xy) {
        // Unpack history data
        float history_depth = 1.0 - history_data.x;
        float pixel_age = min(history_data.y, max_accumulated_frames);

        vec3 history_bent_normal;
        history_bent_normal.xy = history.zw * 2.0 - 1.0;
        history_bent_normal.z = sqrt(
            clamp01(1.0 - dot(history_bent_normal.xy, history_bent_normal.xy))
        );

        // Reproject bent normal
        history_bent_normal
            = history_bent_normal * mat3(gbufferPreviousModelView);
        history_bent_normal = mat3(gbufferModelView) * history_bent_normal;

        // Depth rejection
        float view_norm = rcp_length(view_pos);
        float NoV = abs(dot(view_normal, view_pos))
            * view_norm; // NoV / sqrt(length(view_pos))
        float z0 = screen_to_view_space_depth(
            combined_projection_matrix_inverse,
            depth
        );
        float z1 = screen_to_view_space_depth(
            combined_projection_matrix_inverse,
            history_depth
        );
        float depth_weight
            = exp2(-abs(z0 - z1) * depth_rejection_strength * NoV * view_norm);

        // Offcenter rejection from Jessie, which is originally by Zombye
        // Reduces blur in motion
        vec2 pixel_offset = 1.0
            - abs(2.0
                      * fract(
                          view_res * ao_render_scale * previous_screen_pos.xy
                      )
                  - 1.0);
        float offcenter_rejection = sqrt(pixel_offset.x * pixel_offset.y)
                * offcenter_rejection_strength
            + (1.0 - offcenter_rejection_strength);

        pixel_age
            *= depth_weight * offcenter_rejection * float(history_depth != 1.0);

        // Blend with history
        float history_weight = pixel_age / (pixel_age + 1.0);

        ao = mix(ao, history.xy, history_weight);
        bent_normal = slerp(bent_normal, history_bent_normal, history_weight);

        ambient = vec4(ao, bent_normal.xy * 0.5 + 0.5);
        ambient_history_data = vec2(1.0 - depth, pixel_age + 1.0);
    } else {
        ambient = vec4(ao, bent_normal.xy * 0.5 + 0.5);
        ambient_history_data = vec2(0.0);
    }

    if (is_hand) {
        ambient_history_data.x = 1.0;
    }
}
