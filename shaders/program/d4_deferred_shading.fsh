/*
--------------------------------------------------------------------------------

  Tachyon Shader (a fork of SixthSurge's Photon Shaders)

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

    // Read clouds/aurora/crepuscular rays

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
        if (is_lod) {
            // The LoD gbuffer normal decodes broken (uniformly invalid - NoL
            // never positive), so rebuild the face normal from the depth
            // buffer instead. Taps are taken a couple of pixels apart rather
            // than from raw derivatives: at LoD distances one pixel can span
            // several terrain steps, and per-pixel derivative normals flip
            // orientation pixel to pixel, striping the lighting with moire.
            // On each axis the depth-closer neighbour is used, so normals
            // don't smear across silhouettes
            const int taps_radius = 2;
            ivec2 max_texel = ivec2(view_res * taau_render_scale) - 1;
            ivec2 texel_x0 = clamp(texel - ivec2(taps_radius, 0), ivec2(0), max_texel);
            ivec2 texel_x1 = clamp(texel + ivec2(taps_radius, 0), ivec2(0), max_texel);
            ivec2 texel_y0 = clamp(texel - ivec2(0, taps_radius), ivec2(0), max_texel);
            ivec2 texel_y1 = clamp(texel + ivec2(0, taps_radius), ivec2(0), max_texel);

            float depth_x0 = texelFetch(combined_depth_tex, texel_x0, 0).x;
            float depth_x1 = texelFetch(combined_depth_tex, texel_x1, 0).x;
            float depth_y0 = texelFetch(combined_depth_tex, texel_y0, 0).x;
            float depth_y1 = texelFetch(combined_depth_tex, texel_y1, 0).x;

            bool pick_x1 = abs(depth_x1 - depth) < abs(depth_x0 - depth);
            bool pick_y1 = abs(depth_y1 - depth) < abs(depth_y0 - depth);

            vec2 uv_x = uv
                + vec2((pick_x1 ? texel_x1 : texel_x0) - texel)
                    * view_pixel_size * rcp(taau_render_scale);
            vec2 uv_y = uv
                + vec2((pick_y1 ? texel_y1 : texel_y0) - texel)
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

            vec3 delta_x = pick_x1
                ? position_x - position_view
                : position_view - position_x;
            vec3 delta_y = pick_y1
                ? position_y - position_view
                : position_view - position_y;

            vec3 lod_normal_view = normalize(cross(delta_x, delta_y));
            lod_normal_view = dot(lod_normal_view, position_view) > 0.0
                ? -lod_normal_view
                : lod_normal_view;
            flat_normal = mat3(gbufferModelViewInverse) * lod_normal_view;
            normal = flat_normal;
        }

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
        //                                    LoD border (vanilla render distance, far).
        //                                    Each pixel STOCHASTICALLY picks near or far
        //                                    (pick_far) and TAA resolves the dither to a
        //                                    seamless gradient. A smooth mix instead
        //                                    compressed to a visible contour on steep /
        //                                    grazing terrain (the band maps to only a few
        //                                    screen pixels there); a dithered pick has no
        //                                    coherent edge to see.
        // lod_blend: 0 deep-near -> 1 deep-far, the per-pixel probability of picking far.
        // ---------------------------------------------------------------------------
        float lod_blend = smoothstep(
            far - 0.5 * LOD_BLEND_WIDTH,
            far + 0.5 * LOD_BLEND_WIDTH,
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

            // FAR-MODEL inputs (screenspace), computed only for far-PICKED pixels (the
            // near model ignores them, so near picks skip the SSRT march). For vanilla
            // terrain the LoD buffer is empty here, so the march reads lit / no occlusion.
            if (pick_far) {
#ifdef SHADOW_SSRT
                shadow_distant = get_screen_space_shadows(
                    uv,
                    position_view,
                    depth,
#ifdef LOD_MOD_ACTIVE
                    depth_lod,
#endif
                    light_levels.y,
                    material.sss_amount > eps,
                    sss_depth_distant
                );

                if (material.sss_amount > eps) {
                    sss_screen_occlusion = get_sss_screen_occlusion(
                        uv,
                        position_view,
                        depth
#ifdef LOD_MOD_ACTIVE
                        ,
                        is_lod,
                        depth_lod
#endif
                    );
                }
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
            // Cutout/plant materials (masks 2-5: small/tall plants, leaves; 14: thin
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
                    && (material_mask < 2u || material_mask > 5u)   // not plants/leaves
                    && material_mask != 14u) {                      // thin strong-SSS -> own SSS
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
                    }

                    // Sky-access backstop: a block the sky can't reach gets NO sun rim, whatever
                    // the shadow map reads. In huge caverns the real sun-blocker (surface/ceiling)
                    // lies beyond the shadow map's range, so the shadow read defaults to "lit" and
                    // the rim leaks onto buried solid blocks. Skylight is MC's own lighting, range-
                    // free. HARD floor at 0.1 - a sliver of sky (0.0-0.1) must NOT pass a partial
                    // rim, or deep-cavern blocks with a trace of skylight still glow.
                    rim *= linear_step(0.1, 0.2, light_levels.y);

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
        // TEMP: decompose terrain lighting to find the dark band at the near<->far
        // border. Whichever channel darkens across the band is the responsible
        // term.
        //   R = cast shadow (shadow-map near-field / SSRT far-field); low = shadowed
        //   G = NoL on the shading normal; low = facing from the sun, or a bad
        //       reconstructed LoD normal
        //   B = skylight level (light_levels.y); low = low sky access
        fragment_color = vec3(
            (pick_far ? shadows_far : shadows_near).x,
            clamp01(dot(normal, light_dir)),
            light_levels.y
        );
#endif

    }
}
