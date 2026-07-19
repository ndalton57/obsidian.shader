/*
--------------------------------------------------------------------------------

  Obsidian Shader

  program/d4_deferred_shading:
  Shade terrain and entities, draw sky

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(location = 0) out vec3 fragment_color;

#ifdef USE_SEPARATE_ENTITY_DRAWS
/* RENDERTARGETS: 0 */
#else
layout(location = 1) out vec4 colortex3_clear;

/* RENDERTARGETS: 0,3 */
#endif

in vec2 uv;

flat in vec3 ambient_color;
flat in vec3 light_color;

#if defined WORLD_OVERWORLD
flat in vec3 sun_color;
flat in vec3 moon_color;

#include "/include/fog/overworld/parameters.glsl"
flat in OverworldFogParameters fog_params;

#if defined SH_SKYLIGHT
flat in vec3 sky_sh[9];
flat in vec3 skylight_up;
#endif

flat in float rainbow_amount;
#endif

// ------------
//   Uniforms
// ------------

uniform sampler2D noisetex;

uniform sampler2D colortex0; // skytextured output
uniform sampler2D colortex1; // gbuffer 0
uniform sampler2D colortex2; // gbuffer 1
uniform sampler2D colortex4; // sky map
uniform sampler2D colortex5; // previous frame color
uniform sampler2D colortex6; // ambient lighting data
uniform sampler2D colortex7; // previous frame fog scattering
uniform sampler2D colortex11; // clouds history
uniform sampler2D colortex12; // clouds data
uniform sampler2D colortex14; // ambient lighting history data

#ifndef USE_SEPARATE_ENTITY_DRAWS
uniform sampler2D colortex3; // OF damage overlay, armor glint
#endif

#if defined WORLD_OVERWORLD && defined GALAXY
uniform sampler2D colortex13;
#define galaxy_sampler colortex13
#endif

#ifdef CLOUD_SHADOWS
uniform sampler2D colortex8; // cloud shadow map
#endif

uniform sampler3D depthtex0; // atmosphere scattering LUT
uniform sampler2D depthtex1;

#ifdef COLORED_LIGHTS
uniform sampler3D light_sampler_a;
uniform sampler3D light_sampler_b;
uniform sampler3D sculk_field_sampler; // sculk glow field (d4b_sculk_field)

#if defined WORLD_OVERWORLD && defined COLORED_LIGHTS && defined SCULK_GLOW
// Toroidal trilinear sample of the sculk glow field. A hardware tap cannot
// be used: the texture is a 2048-block world torus, and clamp addressing
// puts a hard seam plane at every 2048-multiple world coordinate plus hard
// cell edges around every pool — the wrap has to be done by hand.
float sample_sculk_field(vec3 world_pos) {
    vec3 p = world_pos * rcp(8.0) - 0.5;
    ivec3 c = ivec3(floor(p));
    vec3 f = fract(p);

    #define SCULK_CELL(dx, dy, dz) texelFetch( \
        sculk_field_sampler, (c + ivec3(dx, dy, dz)) & ivec3(255), 0).x

    float x00 = mix(SCULK_CELL(0, 0, 0), SCULK_CELL(1, 0, 0), f.x);
    float x10 = mix(SCULK_CELL(0, 1, 0), SCULK_CELL(1, 1, 0), f.x);
    float x01 = mix(SCULK_CELL(0, 0, 1), SCULK_CELL(1, 0, 1), f.x);
    float x11 = mix(SCULK_CELL(0, 1, 1), SCULK_CELL(1, 1, 1), f.x);

    #undef SCULK_CELL

    return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}
#endif
uniform usampler3D sss_face_sampler; // SSS leak fix: per-face existence (shadow pass)
#endif

#ifdef BLOCKY_CLOUDS
uniform sampler2D depthtex2; // minecraft cloud texture
#endif

#ifndef WORLD_NETHER
#ifdef SHADOW
uniform sampler2D shadowtex0;
uniform sampler2DShadow shadowtex1;

#ifdef SHADOW_COLOR
uniform sampler2D shadowcolor0;
#endif
#endif
#endif

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowProjectionInverse;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

uniform float eyeAltitude;
uniform float near;
uniform float far;

uniform int worldTime;
uniform int moonPhase;
uniform float sunAngle;
uniform float rainStrength;
uniform float wetness;

uniform int frameCounter;
uniform float frameTimeCounter;

uniform int isEyeInWater;
uniform float blindness;
uniform float nightVision;
uniform float darknessFactor;

uniform vec3 light_dir;
uniform vec3 sun_dir;
uniform vec3 moon_dir;
uniform vec3 view_light_dir;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec2 taa_offset;

uniform float biome_cave;
uniform float biome_may_rain;
uniform float biome_may_snow;

uniform float time_sunrise;
uniform float time_noon;
uniform float time_sunset;
uniform float time_midnight;

uniform float world_age;
uniform float eye_skylight;

/*
const bool colortex5MipmapEnabled = true;
const bool colortex11MipmapEnabled = true;
*/

// ------------
//   Includes
// ------------

#define ATMOSPHERE_SCATTERING_LUT depthtex0
#define TEMPORAL_REPROJECTION

#ifdef PHOTONICS_IN_USE
#define PHOTONICS_DIFFUSE
#endif

#include "/include/fog/simple_fog.glsl"
#include "/include/lighting/diffuse_lighting.glsl"
#include "/include/lighting/shadows/common.glsl"
#include "/include/lighting/shadows/pcss.glsl"
#include "/include/lighting/shadows/ssrt.glsl"
#include "/include/lighting/specular_lighting.glsl"
#include "/include/misc/lod_mod_support.glsl"
#include "/include/misc/material_masks.glsl"
#include "/include/misc/purkinje_shift.glsl"
#include "/include/sky/sky.glsl"
#include "/include/surface/edge_highlight.glsl"
#include "/include/surface/material.glsl"
#include "/include/surface/rain_puddles.glsl"
#include "/include/utility/bicubic.glsl"
#include "/include/utility/color.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/space_conversion.glsl"

#if defined WORLD_OVERWORLD
#include "/include/sky/clouds/sampling.glsl"
#include "/include/sky/rainbow.glsl"
#if defined BLOCKY_CLOUDS
#include "/include/sky/blocky_clouds.glsl"
#endif
#endif

#if defined CLOUD_SHADOWS
#include "/include/lighting/cloud_shadows.glsl"
#endif

#ifdef LOD_MOD_ACTIVE
// Full-resolution spiral SSAO for LoD terrain, computed inline (reference
// architecture): raw depth per tap with the matching projection, a
// screen-proportional disc, and coplanarity rejection so flat treads never
// occlude. Deliberately NOT the d3 pass: half resolution, temporal
// accumulation, and the depth-weighted upsample each imprint artifacts on
// LoD content (terrace banding, ghost images).
float compute_lod_ssao(
    vec2 uv,
    float depth_lod,
    vec3 view_face_normal,
    ivec2 texel,
    float dither
) {
    const int sample_count = 7;

    vec3 view_pos_lod = screen_to_view_space(
        lod_projection_matrix_inverse,
        vec3(uv, depth_lod),
        false
    );

    float view_dist = length(view_pos_lod);
    float distance_scale
        = mix(40.0, 10.0, sqr(clamp01(1.0 - view_dist * (1.0 / 50.0))));
    float range_sq = sqr(view_dist) / distance_scale;

    ivec2 max_texel = ivec2(view_res * taau_render_scale) - 1;

    float occlusion = 0.0;
    float n = 0.0;

    for (int i = 0; i < sample_count; ++i) {
        float angle = (float(i) + dither) * golden_angle;
        float radius = sqrt((float(i) + 0.5) * (1.0 / float(sample_count)));
        vec2 offset_px = radius * vec2(cos(angle), sin(angle))
            * (view_res.x / distance_scale);

        ivec2 tap_texel = clamp(texel + ivec2(offset_px), ivec2(0), max_texel);
        vec2 tap_uv
            = (vec2(tap_texel) + 0.5) * view_pixel_size * rcp(taau_render_scale);

        float tap_depth = texelFetch(depthtex1, tap_texel, 0).x;
        vec3 tap_view;
        if (tap_depth < 1.0) {
            tap_view = screen_to_view_space(
                gbufferProjectionInverse, vec3(tap_uv, tap_depth), true);
        } else {
            tap_depth = texelFetch(lod_depth_tex_solid, tap_texel, 0).x;
            if (tap_depth == 0.0) {
                continue; // empty LoD texel (sky)
            }
            tap_view = screen_to_view_space(
                lod_projection_matrix_inverse, vec3(tap_uv, tap_depth), false);
        }

        vec3 diff = tap_view - view_pos_lod;
        float diff_sq = dot(diff, diff);
        if (diff_sq > 1e-5) {
            vec3 dir = diff * inversesqrt(diff_sq);
            float range_window = max0(1.0 - diff_sq / range_sq);
            n += 1.0;
            // Coplanarity rejection: on-plane samples never occlude
            float pre_ao = 1.0 - clamp01(dot(dir, view_face_normal) * 25.0);
            occlusion += max0(dot(dir, view_face_normal) - pre_ao) * range_window;
        }
    }

    // Contrast shaping: the reference applies a steep curve on its side
    // (pow4 into ambient); a source-side exponent deepens crevice darkening
    // without touching the lit areas. Raise for stronger LoD AO.
    const float lod_ao_contrast = 2.0;
    return pow(max0(1.0 - occlusion / max(n, 1e-5)), lod_ao_contrast);
}
#endif

void main() {
#if !defined USE_SEPARATE_ENTITY_DRAWS
    colortex3_clear = vec4(0.0);
#endif

    ivec2 texel = ivec2(gl_FragCoord.xy);

    // Sample textures

    float depth = texelFetch(combined_depth_tex, texel, 0).x;
    vec4 gbuffer_data_0 = texelFetch(colortex1, texel, 0);
#if defined NORMAL_MAPPING || defined SPECULAR_MAPPING
    vec4 gbuffer_data_1 = texelFetch(colortex2, texel, 0);
#endif
#if !defined USE_SEPARATE_ENTITY_DRAWS
    vec4 overlays = texelFetch(colortex3, texel, 0);
#endif

    // Check for LoD terrain

#ifdef LOD_MOD_ACTIVE
    float depth_mc = texelFetch(depthtex1, texel, 0).x;
    float depth_lod = texelFetch(lod_depth_tex, texel, 0).x;
    bool is_lod = is_lod_terrain(depth_mc, depth_lod);
#else
    const bool is_lod = false;
#define depth_mc depth
#endif

    // Space conversions

    bool is_hand;
    fix_hand_depth(depth_mc, is_hand);

    vec3 position_view = screen_to_view_space(
        combined_projection_matrix_inverse,
        vec3(uv, depth),
        true
    );
    vec3 position_scene = view_to_scene_space(position_view);
    vec3 position_world = position_scene + cameraPosition;
    vec3 direction_world
        = normalize(position_scene - gbufferModelViewInverse[3].xyz);

#if defined WORLD_OVERWORLD
    // Atmosphere

    vec3 atmosphere = atmosphere_scattering(
        direction_world,
        sun_color,
        sun_dir,
        moon_color,
        moon_dir,
        /* use_klein_nishina_phase */ depth == 1.0
    );

    // Read clouds/aurora

    float clouds_apparent_distance;
    vec4 clouds_and_aurora
        = read_clouds_and_aurora(uv, clouds_apparent_distance);

    // Blocky clouds

#ifdef BLOCKY_CLOUDS
    vec3 world_start_pos = gbufferModelViewInverse[3].xyz + cameraPosition;
    vec3 world_end_pos = position_world;

    float dither = texelFetch(noisetex, texel & 511, 0).b;
    dither = r1(frameCounter, dither);

    vec4 blocky_clouds = raymarch_blocky_clouds(
        world_start_pos,
        world_end_pos,
        depth == 1.0,
        blocky_clouds_altitude_l0,
        dither
    );

#ifdef BLOCKY_CLOUDS_LAYER_2
    float visibility = pow4(blocky_clouds.a);
    vec4 blocky_clouds_l2 = raymarch_blocky_clouds(
        world_start_pos,
        world_end_pos,
        depth == 1.0,
        blocky_clouds_altitude_l1,
        dither
    );
    blocky_clouds.rgb += blocky_clouds_l2.xyz * visibility;
    blocky_clouds.a *= mix(1.0, blocky_clouds_l2.a, visibility);
#endif

    float new_alpha = sqr(sqr(blocky_clouds.a));
    blocky_clouds.rgb
        += atmosphere * (1.0 - new_alpha) * (blocky_clouds.a - new_alpha);
    blocky_clouds.a = new_alpha;
#endif
#endif

    if (depth == 1.0) { // Sky
#if defined WORLD_OVERWORLD
        fragment_color = draw_sky(
            direction_world,
            atmosphere,
            clouds_and_aurora,
            clouds_apparent_distance
        );
#else
        fragment_color = draw_sky(direction_world);
#endif

        // Apply blocky clouds
#if defined WORLD_OVERWORLD && defined BLOCKY_CLOUDS
        fragment_color = fragment_color * blocky_clouds.w + blocky_clouds.xyz;
#endif

        // Apply common fog
        vec4 fog = common_fog(far, true);
        fragment_color = mix(fog.rgb, fragment_color.rgb, fog.a);

        // Apply purkinje shift
        fragment_color = purkinje_shift(fragment_color, vec2(0.0, 1.0));
    } else { // Terrain
        // Sample ambient occlusion a while before using it (latency hiding)

        vec2 half_res_pos = gl_FragCoord.xy * (0.5 / taau_render_scale) - 0.5;

        ivec2 i = ivec2(half_res_pos);
        vec2 f = fract(half_res_pos);

        ivec2 p10 = i + ivec2(1, 0);
        ivec2 p01 = i + ivec2(0, 1);
        ivec2 p11 = i + ivec2(1, 1);

        vec4 ambient_00 = texelFetch(colortex6, i, 0);
        vec4 ambient_10 = texelFetch(colortex6, p10, 0);
        vec4 ambient_01 = texelFetch(colortex6, p01, 0);
        vec4 ambient_11 = texelFetch(colortex6, p11, 0);
        float ambient_depth_00 = texelFetch(colortex14, i, 0).x;
        float ambient_depth_10 = texelFetch(colortex14, p10, 0).x;
        float ambient_depth_01 = texelFetch(colortex14, p01, 0).x;
        float ambient_depth_11 = texelFetch(colortex14, p11, 0).x;

        // Unpack gbuffer data

        mat4x2 data = mat4x2(
            unpack_unorm_2x8(gbuffer_data_0.x),
            unpack_unorm_2x8(gbuffer_data_0.y),
            unpack_unorm_2x8(gbuffer_data_0.z),
            unpack_unorm_2x8(gbuffer_data_0.w)
        );

        vec3 albedo = vec3(data[0], data[1].x);
        uint material_mask = uint(255.0 * data[1].y);
        vec3 flat_normal = decode_unit_vector(data[2]);
        vec2 light_levels = data[3];

#if !defined USE_SEPARATE_ENTITY_DRAWS
        uint overlay_id = uint(255.0 * overlays.a);
        albedo = overlay_id == 0u ? albedo + overlays.rgb
                                  : albedo; // enchantment glint
        albedo = overlay_id == 1u && !is_hand
            ? 2.0 * albedo * overlays.rgb
            : albedo; // damage overlay
#endif

        // Get material and normal

        Material material = material_from(
            albedo,
            material_mask,
            position_world,
            flat_normal,
            light_levels
        );

        vec3 normal = flat_normal;
        bool parallax_shadow = false;

#ifdef LOD_MOD_ACTIVE
        // LoD normals come straight from the standard decode above:
        // voxy_opaque.glsl encodes the exact per-face axis normal (from the
        // mod's face enum, nudged off the -Z encoding seam). Per-face
        // quantized normals ARE the vanilla-style face shading on LoD terrain
        // (distinct light levels per face family), and together with the far
        // model's grazing dead zone they keep the screen-space shadow march's
        // noisiest verdicts off-screen. A depth-based smooth reconstruction
        // lived here before - it flattened the face shading away and lit the
        // grazing zone.

        if (!is_lod) {
#endif

#ifdef NORMAL_MAPPING
            normal = decode_unit_vector(gbuffer_data_1.xy);
#endif

#ifdef SPECULAR_MAPPING
            vec4 specular_map = vec4(
                unpack_unorm_2x8(gbuffer_data_1.z),
                unpack_unorm_2x8(gbuffer_data_1.w)
            );
            decode_specular_map(specular_map, material, parallax_shadow);
#elif defined NORMAL_MAPPING
        parallax_shadow = gbuffer_data_1.z >= 0.5;
#endif

#ifdef LOD_MOD_ACTIVE
        }
#endif

        // Rain puddles

#if defined WORLD_OVERWORLD && defined RAIN_PUDDLES
        if (wetness > eps && biome_may_rain > eps) {
            bool puddle = get_rain_puddles(
                position_world,
                flat_normal,
                light_levels,
                material.porosity,
                material_mask,
                normal,
                material.albedo,
                material.f0,
                material.roughness,
                material.ssr_multiplier
            );
        }
#endif

        // Upscale ambient occlusion

        float lin_z = screen_to_view_space_depth(
            combined_projection_matrix_inverse,
            depth
        );

#define depth_weight(reversed_depth) \
    exp2( \
        -10.0 \
        * abs( \
            screen_to_view_space_depth( \
                combined_projection_matrix_inverse, \
                1.0 - reversed_depth \
            ) \
            - lin_z \
        ) \
    )
        float w00 = depth_weight(ambient_depth_00) * (1.0 - f.x) * (1.0 - f.y);
        float w10 = depth_weight(ambient_depth_10) * (f.x - f.x * f.y);
        float w01 = depth_weight(ambient_depth_01) * (f.y - f.x * f.y);
        float w11 = depth_weight(ambient_depth_11) * (f.x * f.y);
#undef depth_weight

        vec4 ambient_upscaled;
        float weight_sum = w00 + w10 + w01 + w11;

        if (abs(weight_sum) > eps) {
            ambient_upscaled = ambient_00 * w00 + ambient_10 * w10
                + ambient_01 * w01 + ambient_11 * w11;

            ambient_upscaled *= rcp(weight_sum);
        } else {
            ambient_upscaled = ambient_00;
        }

        float ao = ambient_upscaled.x;
        float ambient_sss = ambient_upscaled.y;

        vec3 bent_normal;
        bent_normal.xy = ambient_upscaled.zw * 2.0 - 1.0;
        bent_normal.z
            = sqrt(clamp01(1.0 - dot(bent_normal.xy, bent_normal.xy)));
        bent_normal = mat3(gbufferModelViewInverse) * bent_normal;

#ifdef LOD_MOD_ACTIVE
        if (is_lod) {
            // Inline full-res LoD SSAO replaces the d3 value entirely - see
            // compute_lod_ssao above.
            float lod_dither = texelFetch(noisetex, texel & 511, 0).b;
            lod_dither = r1(frameCounter, lod_dither);
            ao = compute_lod_ssao(
                uv,
                depth_lod,
                mat3(gbufferModelView) * flat_normal,
                texel,
                lod_dither
            );
            ambient_sss = 0.0;
            bent_normal = flat_normal;
        }
#endif

        // Sense check bent normal
        if (dot(bent_normal, normal) < eps) {
            bent_normal = normal;
        }

        // No AO/bent normal on hand
        if (is_hand) {
            ao = 1.0;
            bent_normal = normal;
        }

        // Calculate lighting dot products

        // Grazing-sun handling (fixes normal-map terminator speckle and the hard-cut
        // snap as the sun crosses the noon zenith). Near grazing the sun diffuse is
        // driven by the FLAT face at its rectified brightness (NoL_rect: a softplus that
        // never hard-zeros), so it stays uniform - the normal map can't push NoL across
        // zero and shatter the face into speckle - and it keeps the lit colour the bumps
        // averaged to rather than going dark. The per-texel normal returns as relief once
        // the face is clearly lit. The terminator itself is faded on the shadow (pcss).
        float NoL_flat = dot(flat_normal, light_dir);
        float NoL_rect
            = 0.5 * (NoL_flat + sqrt(sqr(NoL_flat) + sqr(SUN_TERMINATOR_SOFTNESS)));
        float NoL = mix(
            NoL_rect,
            dot(normal, light_dir),
            smoothstep(0.0, GRAZING_DETAIL_RETURN, NoL_flat)
        );
        float NoV = clamp01(dot(normal, -direction_world));
        float LoV = dot(light_dir, -direction_world);
        float halfway_norm = inversesqrt(2.0 * LoV + 2.0);
        float NoH = (NoL + NoV) * halfway_norm;
        float LoH = LoV * halfway_norm + halfway_norm;

        // Cloud shadows

#if defined WORLD_OVERWORLD && defined CLOUD_SHADOWS
        float cloud_shadows = get_cloud_shadows(colortex8, position_scene);
#else
        const float cloud_shadows = 1.0;
#endif

        // Shadows

        // SSS edge-wrap rim factor + the material's original SSS strength: captured by
        // the gate below, then added as a bleed AFTER the base lighting lights the faces normally
        // (so the rim never changes how lit a face is). dbg mirrors the rim for debug.
        float dbg_sun_occlusion = -1.0;
        float sss_rim = 0.0;
        float sss_str = 0.0;

#if defined WORLD_OVERWORLD || defined WORLD_END
        // ---------------------------------------------------------------------------
        // TERRAIN LIGHTING - THREE ZONES, TWO MODELS. Each fragment is shaded by exactly
        // ONE complete model; the two are NEVER numerically blended (a smooth mix muddied
        // both and read as a distinct "third look"). The zones, by view distance:
        //   NEAR FIELD (deep vanilla)     -> NEAR model: shadow-map cast shadows + shadow-map
        //                                    SSS + edge-wrap rim.
        //   FAR FIELD  (deep Voxy LoD)    -> FAR model:  SSRT shadows + screenspace SSS,
        //                                    plus the distant-ambient dimming.
        //   MID FIELD  (the transition)   -> a LOD_BLEND_WIDTH-wide band centred on the
        //                                    SHADOW-DATA border, min(shadowDistance, far):
        //                                    the near model is only ever picked where the
        //                                    shadow map has data. Past it, EVERYTHING is
        //                                    far field - real vanilla terrain past
        //                                    shadowDistance and Voxy LoD run the same far
        //                                    model with the same inputs, so the two never
        //                                    read differently. When the shadow map covers
        //                                    the whole render distance this border IS the
        //                                    LoD border. KNOWN LIMIT: on dense vanilla
        //                                    micro-geometry (grass crosses) the far
        //                                    model's screen-space march has residual
        //                                    camera-motion flicker; the planned fix is a
        //                                    min-depth pyramid for the march, not model
        //                                    re-routing (a dark near-model band reads
        //                                    worse than the flicker).
        //                                    Each pixel STOCHASTICALLY picks near or far
        //                                    (pick_far) and TAA resolves the dither to a
        //                                    seamless gradient. A smooth mix instead
        //                                    compressed to a visible contour on steep /
        //                                    grazing terrain (the band maps to only a few
        //                                    screen pixels there); a dithered pick has no
        //                                    coherent edge to see.
        // lod_blend: 0 deep-near -> 1 deep-far, the per-pixel probability of picking far.
        // ---------------------------------------------------------------------------
        float fork_border = min(shadowDistance, far);
        float lod_blend = smoothstep(
            fork_border - 0.5 * LOD_BLEND_WIDTH,
            fork_border + 0.5 * LOD_BLEND_WIDTH,
            length(position_scene)
        );

        // Blue noise + per-frame R1 rotation so TAA averages the stochastic pick clean.
        float blend_dither = texelFetch(noisetex, ivec2(gl_FragCoord.xy) & 511, 0).b;
        blend_dither = r1(frameCounter, blend_dither);
        bool pick_far = blend_dither < lod_blend;

        vec3 shadows_near = vec3(1.0);
        vec3 shadows_far = vec3(1.0);
        float shadow_distance_fade = 1.0;
        float sss_depth_near_model = 0.0;
        float sss_depth_far_model = 0.0;
        float sss_screen_occlusion = 0.0;
        Material material_near = material;

        // Run UNCONDITIONALLY - do NOT gate on the sun angle. get_filtered_shadows
        // writes shadow_distance_fade; gating on NoL left it stale on faces turned from
        // the sun, snapping a near wall onto the far model in one step (the noon-zenith
        // flicker). Back-faces cost little: the shadow filter early-outs internally.
        {
            vec3 shadow_near = vec3(0.0);
            float shadow_distant = 0.0;
            float sss_depth_near = 0.0;
            float sss_depth_distant = 0.0;

#ifdef SHADOW
            shadow_near = get_filtered_shadows(
                position_scene,
                flat_normal,
                light_levels.y,
                cloud_shadows,
                material.sss_amount,
                shadow_distance_fade,
                sss_depth_near
            );
#endif

            // Beyond the shadow map (fade == 1) get_filtered_shadows leaves sss_depth
            // at 0, which reads as "infinitely thin" = full transmission (sunlight
            // bleeds through solid unmapped terrain). Force fully occluded there.
            sss_depth_near_model
                = shadow_distance_fade >= 1.0 ? 100.0 : sss_depth_near;

            // NEAR-MODEL shadow: real shadow-map shadow for vanilla; for LoD terrain
            // (not in the shadow map) force lit, so the near model never throws a stale
            // shadow-map read onto Voxy in the band.
            shadows_near = is_lod ? vec3(1.0) : shadow_near;

#ifdef SHADOW
            // HAND: its deferred position is a synthetic point at the camera
            // (combined depth stores 0 as the hand signal), inside the
            // player's own shadow-map footprint - the terrain tap there reads
            // whatever the bias escapes to, so the hand never tracks shade.
            // Light it by the PLAYER's sun visibility instead: one probe at a
            // fixed point sunward of the eye. The probe floats in open air
            // (clear of the player model at any sun angle, no surface = no
            // acne), so it is occluded exactly when something stands between
            // the player and the sun.
            if (is_hand) {
                vec3 probe_clip = project_ortho(
                    shadowProjection,
                    transform(shadowModelView, light_dir * 0.75)
                );
                vec3 probe_screen
                    = distort_shadow_space(probe_clip) * 0.5 + 0.5;
                shadows_near = shadow_basic(probe_screen);
            }
#endif

            // FAR-MODEL inputs (screenspace), computed only for far-PICKED pixels (the
            // near model ignores them, so near picks skip the SSRT march). For vanilla
            // terrain the LoD buffer is empty here, so the march reads lit / no occlusion.
            if (pick_far) {
#ifdef SHADOW_SSRT
#ifdef LOD_MOD_ACTIVE
                if (is_lod) {
                    // ONE fixed-step march yields both the cast shadow and the
                    // SSS burial fraction for LoD terrain (see
                    // get_sss_screen_occlusion). The near-field contact-shadow
                    // marcher (geometric steps, absolute thickness window)
                    // aliases into stripes at LoD scale and must not run here.
                    vec2 lod_light = get_sss_screen_occlusion(
                        uv,
                        position_view,
                        depth,
                        true,
                        depth_lod
                    );
                    shadow_distant = lod_light.x;
                    sss_screen_occlusion = lod_light.y;
                    // Thin-surface baseline: the transmission is shaped by the
                    // occlusion ray, not by a marched light path.
                    sss_depth_distant = 0.0;
                } else {
                    // Vanilla far-field: lit (no LoD data to march; marching
                    // the vanilla depth at far-field scale mass-shadows real
                    // terrain relief). Transmission still gets the occlusion
                    // ray against the combined depth.
                    shadow_distant = 1.0;
                    sss_depth_distant = 0.0;
                    if (material.sss_amount > eps) {
                        sss_screen_occlusion = get_sss_screen_occlusion(
                            uv,
                            position_view,
                            depth,
                            false,
                            depth_lod
                        ).y;
                    }
                }
#else
                shadow_distant = get_screen_space_shadows(
                    uv,
                    position_view,
                    depth,
                    light_levels.y,
                    material.sss_amount > eps,
                    sss_depth_distant
                );

                if (material.sss_amount > eps) {
                    sss_screen_occlusion = get_sss_screen_occlusion(
                        uv,
                        position_view,
                        depth
                    ).y;
                }
#endif
#else
                shadow_distant = get_lightmap_shadows(light_levels.y);
#endif
            }
            sss_depth_far_model = sss_depth_distant;
            shadows_far = vec3(shadow_distant);

            // SSS EDGE-WRAP rim - the NEAR model's SSS for SOLID blocks (per block,
            // view-INDEPENDENT, NO marching; the shaded face's edges wrap light from the
            // perpendicular faces of THIS block, each contributing only if it was DRAWN
            // and by how much sun hit it). Near-PICKED, near-field geometry only: it reads
            // the shadow-pass face data / voxel volume, which LoD terrain isn't in.
            // Cutout/plant materials (masks 2-5: small/tall plants, leaves; 82/83/85:
            // grass-shader split-outs of tall/short grass; 14: thin
            // strong-SSS) are skipped and keep their own per-fragment SSS - the rim is a SOLID-CUBE
            // model, and running it on plant geometry floating above its block leaked
            // shadow-map structure as banding "waves". For solid blocks it REPLACES the
            // per-fragment SSS in the near model (material_near.sss_amount -> 0; the bleed is added
            // separately), while the far model keeps the original sss_amount for its
            // screenspace SSS. See update_sss_faces + face_sun_light.
#if defined COLORED_LIGHTS && defined SHADOW
                if (!pick_far
                    && !is_lod
                    && material.sss_amount > eps
                    && !is_thin_plant_mask(material_mask) // plants/grass -> own SSS
                    && material_mask != 14u               // thin strong-SSS -> own SSS
                    && material_mask != 113u) {           // animals: never voxelized, no
                                                          // faces for a rim -> own SSS
                    vec3 block_center
                        = floor(position_world - flat_normal * 0.5) + 0.5;
                    ivec3 block_cell
                        = ivec3(scene_to_voxel_space(block_center - cameraPosition));
                    uint own_mask = is_inside_voxel_volume(vec3(block_cell))
                        ? texelFetch(sss_face_sampler, block_cell, 0).x
                        : 0u;

                    // Unconditional suppression is the no-leak guarantee. own_mask holds this
                    // block's drawn faces; with NO faces (own_mask == 0 - e.g. a face beyond the
                    // voxel volume) the loop is skipped, rim stays 0, and the block goes dark. It
                    // must NEVER fall back to the per-fragment SSS, which bleeds through solid terrain.
                    float rim = 0.0;
                    if (material_mask == 84u) {
                        // Thin snow LAYER. The cube edge-wrap rim below can't place its geometry:
                        // a 1-layer slab sits on the cell floor, so its side faces read as "below
                        // centre" and the top-face contribution clamps to zero - only a full 8-layer
                        // slab fills the cell and lights up. Snow is a translucent slab anyway, so
                        // glow the whole surface by how much sun reaches its top (sampled just above
                        // to dodge self-shadow). Sun- AND skylight-gated below, so no shade/cave leak.
                        vec3 top = position_world + vec3(0.0, 1.0 / 16.0, 0.0);
                        rim = clamp01(face_sun_light(
                            top - cameraPosition, vec3(0.0, 1.0, 0.0), light_levels.y));
                    } else if (own_mask != 0u) {
                        vec3 f = position_world - block_center; // -0.5..0.5 within block
                        const vec3 dirs[6] = vec3[6](
                            vec3( 1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0),
                            vec3( 0.0, 1.0, 0.0), vec3( 0.0,-1.0, 0.0),
                            vec3( 0.0, 0.0, 1.0), vec3( 0.0, 0.0,-1.0));

                        for (int i = 0; i < 6; ++i) {
                            vec3 d = dirs[i];
                            if (abs(dot(d, flat_normal)) > 0.5) {
                                continue; // skip the 2 faces parallel to the shaded one
                            }
                            float prox = max0(dot(f, d) * 2.0); // 0 centre -> 1 at d edge
                            prox *= prox;                       // sharpen the rim (continuous)
                            if (prox < 1e-3 || (own_mask & sss_face_bit(d)) == 0u) {
                                continue; // not near this edge, or its face wasn't drawn
                            }
                            // Sample face d at this fragment's spot along the shared edge, one texel
                            // IN from the edge so the read patch stays ON face d - not the open air
                            // past the edge, which read as lit and bled glow onto the side.
                            vec3 tangential
                                = f - dot(f, d) * d - dot(f, flat_normal) * flat_normal;
                            vec3 edge_point = block_center + 0.5 * d
                                + (0.5 - 1.0 / 16.0) * flat_normal + tangential;
                            rim += prox
                                * face_sun_light(edge_point - cameraPosition, d, light_levels.y);
                        }
                        rim = clamp01(rim);

                        // A face turned INTO the sun has no light to wrap
                        // around its edges - every texel on it already sees
                        // the sun directly, so the wrap fades out as the
                        // face swings toward the light. Shadow-side and
                        // grazing faces (NoL <= 0) keep the full rim. Flat
                        // normal: the rim is a per-face block model.
                        rim *= 1.0 - clamp01(dot(flat_normal, light_dir));
                    }

                    // Sky-access backstop: a block the sky can't reach gets NO sun rim, whatever
                    // the shadow map reads. In huge caverns the real sun-blocker (surface/ceiling)
                    // lies beyond the shadow map's range, so the shadow read defaults to "lit" and
                    // the rim leaks onto buried solid blocks. Skylight is MC's own lighting, range-
                    // free. HARD floor at 0.1 - a sliver of sky (0.0-0.1) must NOT pass a partial
                    // rim, or deep-cavern blocks with a trace of skylight still glow.
                    rim *= linear_step(0.1, 0.2, light_levels.y);

                    // The rim borrows SUN light, so it dims with the same
                    // cloud-shadow factor as the direct term. face_sun_light
                    // reads only the geometric shadow map - clouds are not
                    // in it - so without this the rim stays full-bright
                    // while the face itself darkens under cloud cover.
                    rim *= cloud_shadows;

                    dbg_sun_occlusion = 1.0 - rim;
                    // Don't touch base lighting: the base model lights each face normally
                    // (sss_amount = 0); the rim is added separately below as the bleed.
                    sss_rim = rim;
                    sss_str = material.sss_amount;
                    material_near.sss_amount = 0.0;
                }
#endif
            // Light Leak Fix (mode 2) - on BOTH models' shadows so it covers every sun
            // path: shadow map, SSRT, and the lightmap fallback beyond the shadow map.
            float light_leak = get_lightmap_light_leak_prevention(
                light_levels.y,
                eye_skylight
            );
            shadows_near *= light_leak;
            shadows_far *= light_leak;

            // Apply parallax shadow
#if defined POM && defined POM_SHADOW \
    && (defined SPECULAR_MAPPING || defined NORMAL_MAPPING)
            shadows_near *= float(!parallax_shadow);
            shadows_far *= float(!parallax_shadow);
#endif
        }
#else
        const float lod_blend = 1.0; // no LoD fork outside overworld/end; far model only
        const bool pick_far = true;
        const vec3 shadows_near = vec3(1.0);
        const vec3 shadows_far = vec3(1.0);
        const float shadow_distance_fade = 1.0;
        const float sss_depth_near_model = 0.0;
        const float sss_depth_far_model = 0.0;
        const float sss_screen_occlusion = 0.0;
        Material material_near = material;
#endif

        // SSS distance trust: how far the SSRT-measured light path can be relied
        // on, by VIEW distance so it is static under a moving sun (a shadow-space
        // fade crawled rings across distant SSS terrain). Beyond it the screen-
        // space occlusion ray is the only signal shaping the transmission.
#if defined WORLD_OVERWORLD || defined WORLD_END
        float sss_range = min(shadowDistance, max(far - 32.0, 32.0));
        float sss_distance_fade = 1.0
            - smoothstep(0.0, 1.0,
                min(max(1.0 - length(position_scene) / sss_range, 0.0) * 5.0, 1.0));
        // Also kill SSS where the shadow map has no data (low sun shrinks its
        // usable area): an unmeasured path reads as zero depth = full transmission.
        sss_distance_fade = max(sss_distance_fade, clamp01(shadow_distance_fade));
#else
        const float sss_distance_fade = 0.0;
#endif

        // Diffuse lighting. Each pixel runs exactly ONE model - the one it picked - with
        // that model's own shadows / SSS inputs; the MID-field dither + TAA blend the two
        // across the band. The other stays vec3(0) and is never read.
        vec3 lighting_near = vec3(0.0);
        vec3 lighting_far = vec3(0.0);

        if (!pick_far) {
            lighting_near = get_diffuse_lighting(
                material_near,
                position_scene,
                normal,
                flat_normal,
                bent_normal,
                shadows_near,
                light_levels,
                ao,
                ambient_sss,
                sss_depth_near_model,
                true, // is_near_field
                0.0,  // sss_screen_occlusion - far model only
#ifdef CLOUD_SHADOWS
                cloud_shadows,
#endif
                sss_distance_fade,
#ifdef PHOTONICS_DIFFUSE
                is_lod,
#endif
                NoL,
                NoV,
                NoH,
                LoV
            );
        }

        if (pick_far) {
            lighting_far = get_diffuse_lighting(
                material,
                position_scene,
                normal,
                flat_normal,
                bent_normal,
                shadows_far,
                light_levels,
                ao,
                ambient_sss,
                sss_depth_far_model,
                false, // is_near_field
                sss_screen_occlusion,
#ifdef CLOUD_SHADOWS
                cloud_shadows,
#endif
                sss_distance_fade,
#ifdef PHOTONICS_DIFFUSE
                is_lod,
#endif
                NoL,
                NoV,
                NoH,
                LoV
            );
        }

        fragment_color = pick_far ? lighting_far : lighting_near;

        // SSS edge-wrap rim bleed - added ON TOP of the normal per-face lighting.
        // sss_rim is high only at edges where a drawn, sunlit perpendicular face wraps
        // light around the corner, so this is a rim, not a flood, and it never changes
        // how lit the faces themselves are.
#if defined COLORED_LIGHTS && defined SHADOW
        // Near-model bleed; only near-PICKED pixels reach it (sss_rim is 0 otherwise).
        if (sss_rim > 0.0) {
            float rim_phase = 0.3 + 0.7 * henyey_greenstein_phase(-LoV, 0.5);
            fragment_color += (sss_rim * sss_str * SSS_INTENSITY * rim_phase
                    * float(!pick_far))
                * material.albedo * light_color;
        }
#endif

        // Specular highlight

#if defined WORLD_OVERWORLD || defined WORLD_END
        fragment_color
            += get_specular_highlight(material, NoL, NoV, NoH, LoV, LoH)
            * light_color * (pick_far ? shadows_far : shadows_near)
            * cloud_shadows * ao;
#endif

        // Specular reflections

#if defined ENVIRONMENT_REFLECTIONS || defined SKY_REFLECTIONS
        if (material.ssr_multiplier > eps) {
            mat3 tbn = get_tbn_matrix(normal);

            fragment_color += get_specular_reflections(
                material,
                tbn,
                vec3(uv, depth),
                position_view,
                position_world,
                normal,
                flat_normal,
                direction_world,
                direction_world * tbn,
                light_levels.y,
                false
            );
        }
#endif
        // Edge highlight

#ifdef EDGE_HIGHLIGHT
        fragment_color *= 1.0
            + 0.5
                * get_edge_highlight(
                    position_scene,
                    flat_normal,
                    depth,
                    material_mask
                );
#endif

        // Sculk ambiance: the teal light sculk casts on its surroundings,
        // read from the persistent world-anchored glow field (see
        // d4b_sculk_field.csh). World-locked — camera position and rotation
        // cannot move it — and driven by the real material mask near AND
        // far, so it works from the player's feet to the LoD horizon. One
        // trilinear tap gives a soft 8-16 block pool around each stamped
        // cell. Sculk surfaces receive it too (excluding them inverts the
        // contrast: a patch must never read darker than its own pool).
        //
        // PURELY ADDITIVE, with no reference to the voxel volume: every
        // volume-coupled term tried here (membership gates, floodfill
        // subtraction) painted the volume's moving boundary onto the
        // terrain as lines, bands, or a camera-following cube. The field
        // is dim enough that overlapping the real floodfill pools is
        // imperceptible.
#if defined WORLD_OVERWORLD && defined COLORED_LIGHTS && defined SCULK_GLOW
        {
            const vec3 sculk_light_color = vec3(0.75, 1.00, 0.83);
            const float sculk_ambiance_intensity
                = 0.25 * SCULK_GLOW_INTENSITY; // 0.25 = tune HERE

            float sculk_glow = sample_sculk_field(position_world);

            fragment_color += material.albedo * ao * sculk_light_color
                * (sculk_glow * sculk_ambiance_intensity);
        }
#endif

        // Apply fog

        float view_distance = length(position_view);

#ifdef BORDER_FOG
#if defined WORLD_OVERWORLD
        vec3 horizon_dir = normalize(
            vec3(direction_world.xz, min(direction_world.y, -0.1)).xzy
        );
        vec3 horizon_color = texture(colortex4, project_sky(horizon_dir)).rgb;

        float horizon_factor
            = linear_step(0.1, 1.0, exp(-75.0 * sqr(sun_dir.y + 0.0496)));
        horizon_factor = clamp01(horizon_factor + step(0.01, rainStrength));
        horizon_factor = max(
            horizon_factor,
            dampen(linear_step(0.15, 0.05, direction_world.y))
        );

        vec3 border_fog_color
            = mix(atmosphere, horizon_color, sqr(horizon_factor))
            * (1.0 - biome_cave);
#else
        vec3 border_fog_color
            = texture(colortex4, project_sky(direction_world)).rgb;
#endif

        float border_fog = border_fog(position_scene, direction_world);
        fragment_color = mix(border_fog_color, fragment_color, border_fog);
#endif

        vec4 fog = common_fog(view_distance, false);
        fragment_color = fragment_color * fog.a + fog.rgb;

#if defined WORLD_OVERWORLD
        // Apply clouds in front of terrain

#ifdef BLOCKY_CLOUDS
        fragment_color = fragment_color * blocky_clouds.w + blocky_clouds.xyz;
#else
        if (sqr(clouds_apparent_distance) < length_squared(position_view)) {
            fragment_color
                = fragment_color * clouds_and_aurora.w + clouds_and_aurora.xyz;
        }
#endif

        // Apply rainbows in front of terrain

#ifdef RAINBOWS
        fragment_color = draw_rainbows(
            fragment_color,
            direction_world,
            min(view_distance,
                mix(clouds_apparent_distance,
                    1e6,
                    linear_step(1.0, 0.95, clouds_and_aurora.w)))
        );
#endif
#endif

        // Apply purkinje shift

        fragment_color = purkinje_shift(fragment_color, light_levels);

#ifdef LOD_REGIME_DEBUG
        // TEMP diagnostic: which lighting regime is this fragment in?
        //   RED          = near-field (is_lod=false) -> shadow-map model
        //   BLUE         = far-field (is_lod=true) with sss_amount==0 (NO SSS material)
        //   CYAN (b+grn) = far-field with sss_amount>0 -> screenspace model;
        //                  green brightness = sss_amount
        if (!is_lod) {
            fragment_color = vec3(0.4, 0.0, 0.0);
        } else {
            fragment_color = vec3(0.0, material.sss_amount, 0.3);
        }
#endif

#ifdef SSS_THICKNESS_DEBUG
        // TEMP: SSS leak gate, painted on every SSS block. RED = sun path clear
        // (exposed) -> it can glow. GREEN = sun path blocked by solid terrain ->
        // suppressed. Buried faces and blocks tucked behind terrain should read green.
        if (dbg_sun_occlusion >= 0.0) {
            fragment_color = mix(
                vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), clamp01(dbg_sun_occlusion));
        }
#endif

#ifdef BORDER_DEBUG
        // TEMP: stage-isolation decomposition for the LoD stripe hunt.
        //   R = shadow value AS CONSUMED (shadows_far/near after every
        //       multiply: fallbacks, light leak, ...); low = shadowed
        //   G = raw Voxy lightmap sky level (light_levels.y)
        //   B = FRESH raw march verdict, straight from the marcher with
        //       nothing applied after it (LoD pixels only; 0.5 elsewhere)
        // Stripes in B = the march itself (its input uniforms). Stripes in R
        // but NOT B = the consumption chain between march and pixel. Stripes
        // in G = the baked lightmap feeding fallbacks/ambient.
        float dbg_raw_march = 0.5;
#if defined SHADOW_SSRT && defined LOD_MOD_ACTIVE
        if (is_lod) {
            dbg_raw_march = get_sss_screen_occlusion(
                uv, position_view, depth, true, depth_lod).x;
        }
#endif
        fragment_color = vec3(
            (pick_far ? shadows_far : shadows_near).x,
            light_levels.y,
            dbg_raw_march
        );
#endif

    }
}
