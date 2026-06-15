#if !defined INCLUDE_LIGHTING_SHADOWS
#define INCLUDE_LIGHTING_SHADOWS

#if defined SHADOW && (defined WORLD_OVERWORLD || defined WORLD_END)

#include "/include/lighting/shadows/common.glsl"
#include "/include/lighting/shadows/distortion.glsl"
#include "/include/utility/color.glsl"
#include "/include/utility/dithering.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/rotation.glsl"
#include "/include/utility/sampling.glsl"

const ivec2[9] blur_kernel_offsets_3x3 = ivec2[9](
    ivec2(-1, -1),
    ivec2(0, -1),
    ivec2(1, -1),
    ivec2(-1, 0),
    ivec2(0, 0),
    ivec2(1, 0),
    ivec2(-1, 1),
    ivec2(0, 1),
    ivec2(1, 1)
);

const int shadow_map_res = int(float(shadowMapResolution) * MC_SHADOW_QUALITY);
const float shadow_map_pixel_size = rcp(float(shadow_map_res));

vec2 blocker_search(vec3 scene_pos, float dither, bool has_sss) {
    int step_count = has_sss ? SSS_STEPS : 3;

    vec3 shadow_view_pos = transform(shadowModelView, scene_pos);
    vec3 shadow_clip_pos = project_ortho(shadowProjection, shadow_view_pos);
    float ref_z = shadow_clip_pos.z * (SHADOW_DEPTH_SCALE * 0.5) + 0.5;

    float radius = SHADOW_BLOCKER_SEARCH_RADIUS * shadowProjection[0].x
        * (0.5 + 0.5 * linear_step(0.2, 0.4, light_dir.y));

    float depth_sum = 0.0;
    float weight_sum = 0.0;
    float depth_sum_sss = 0.0;

    for (int i = 0; i < step_count; ++i) {
        vec2 offset = vogel_disc_sample(i, step_count, dither * tau) * radius;
        vec2 uv = shadow_clip_pos.xy + offset;
        uv /= get_distortion_factor(uv);
        uv = uv * 0.5 + 0.5;

        float depth = texelFetch(shadowtex0, ivec2(uv * shadow_map_res), 0).x;
        float weight = step(depth, ref_z);

        depth_sum += weight * depth;
        weight_sum += weight;
        depth_sum_sss += max0(ref_z - depth);
    }

    float blocker_depth = weight_sum == 0.0 ? 0.0 : depth_sum / weight_sum;
    float sss_depth = -shadowProjectionInverse[2].z * depth_sum_sss
        * rcp(SHADOW_DEPTH_SCALE * float(step_count));

    return vec2(blocker_depth, sss_depth);
}

// SSS rim glow: how much sun reaches ONE exposed face of a block - the "light level"
// the edge-wrap model wraps around the shared edge. Returns shadow visibility * how
// head-on the sun hits the face (NoL); 0 = dark. CALLER MUST only pass faces the
// per-block mask says were DRAWN - sampling a buried face is the bias-escape bug. On a
// drawn (exposed) face the sample sits on a real surface, so the bias can't escape.
float face_sun_light(vec3 scene_pos, vec3 normal, float skylight) {
    float NoL = dot(normal, light_dir);
    if (NoL < 1e-3) {
        return 0.0; // face turned away from the sun
    }
    vec3 biased = scene_pos + get_shadow_bias(scene_pos, normal, NoL, skylight);
    vec3 clip = project_ortho(shadowProjection, transform(shadowModelView, biased));
    vec3 scr = distort_shadow_space(clip) * 0.5 + 0.5;
    if (clamp01(scr.xy) != scr.xy) {
        return NoL; // outside the shadow map -> assume lit
    }
    // PCF the read over a TIGHT, fixed WORLD patch (offset in clip, distort each tap, like
    // shadow_pcf). A single tap swims as the shadow map's grid re-centres on the moving player;
    // averaging a world-fixed patch holds it steady. Kept to ~one block-texel so it (a) stays on
    // the sampled face instead of bleeding past the edge into open air, and (b) reads the precise
    // texel the caller asked for rather than a wide average. 16 Vogel taps for even coverage.
    float radius = (1.0 / 16.0) * shadowProjection[0].x; // ~1 block-texel, stays on the face
    const int taps = 16;
    float vis = 0.0;
    for (int i = 0; i < taps; ++i) {
        vec2 offset = vogel_disc_sample(i, taps, 0.0) * radius;
        vec3 c = vec3(clip.xy + offset, clip.z);
        vis += texture(shadowtex1, distort_shadow_space(c) * 0.5 + 0.5);
    }
    return (vis * (1.0 / float(taps))) * NoL;
}

vec3 shadow_basic(vec3 shadow_screen_pos) {
    float shadow = texture(shadowtex1, shadow_screen_pos);

#ifdef SHADOW_COLOR
    ivec2 texel = ivec2(shadow_screen_pos.xy * shadow_map_res);

    float depth = texelFetch(shadowtex0, texel, 0).x;
    vec3 color = texelFetch(shadowcolor0, texel, 0).rgb * 4.0;
    float weight = step(depth, shadow_screen_pos.z);

    vec3 averageColor = vec3(0.0);
    for (int i = 0; i < 9; ++i) {
        averageColor
            += texelFetch(shadowcolor0, texel + blur_kernel_offsets_3x3[i], 0)
                   .rgb;
    }
    // hide sunlight seams between colored shadow and opaque shadows
    weight *= step(eps, max_of(averageColor));

    color = color * weight + (1.0 - weight);

    return shadow * color;
#else
    return vec3(shadow);
#endif
}

vec3 shadow_pcf(
    vec3 shadow_screen_pos,
    vec3 shadow_clip_pos,
#ifdef SHADOW_COLOR
    vec3 shadow_screen_pos_translucent,
    vec3 shadow_clip_pos_translucent,
#endif
    float penumbra_size,
    float dither
) {
    // penumbra_size > max_filter_radius: blur
    // penumbra_size < min_filter_radius: anti-alias (blur then sharpen)
    float distortion_factor = get_distortion_factor(shadow_clip_pos.xy);
    float min_filter_radius = 2.0 * shadow_map_pixel_size * distortion_factor;

    float filter_radius = max(penumbra_size, min_filter_radius);
    float filter_scale = sqr(filter_radius / min_filter_radius);

    int step_count
        = int(SHADOW_PCF_STEPS_MIN + SHADOW_PCF_STEPS_SCALE * filter_scale);
    step_count = min(step_count, SHADOW_PCF_STEPS_MAX);

    float shadow = 0.0;

    vec3 color_sum = vec3(0.0);
    float weight_sum = 0.0;

    // perform first 4 iterations and filter shadow color
    for (int i = 0; i < 4; ++i) {
        vec2 offset
            = vogel_disc_sample(i, step_count, dither * tau) * filter_radius;

        vec2 uv = shadow_clip_pos.xy + offset;
        uv /= get_distortion_factor(uv);
        uv = uv * 0.5 + 0.5;

        shadow += texture(shadowtex1, vec3(uv, shadow_screen_pos.z));

#ifdef SHADOW_COLOR
        // sample shadow color
        uv = shadow_clip_pos_translucent.xy + offset;
        uv /= get_distortion_factor(uv);
        uv = uv * 0.5 + 0.5;

        ivec2 texel = ivec2(uv * shadow_map_res);

        float depth = texelFetch(shadowtex0, texel, 0).x;

        vec3 color = texelFetch(shadowcolor0, texel, 0).rgb;
        color = mix(
            vec3(1.0),
            4.0 * color,
            step(depth, shadow_screen_pos_translucent.z)
        );

        float weight = 1.0;

        color_sum += color * weight;
        weight_sum += weight;
#endif
    }

    vec3 color = weight_sum > 0.0 ? color_sum * rcp(weight_sum) : vec3(1.0);

    // exit early if outside shadow
    if (shadow > 4.0 - eps) {
        return color;
    } else if (shadow < eps) {
        return vec3(0.0);
    }

    // perform remaining iterations
    for (int i = 4; i < step_count; ++i) {
        vec2 offset
            = vogel_disc_sample(i, step_count, dither * tau) * filter_radius;

        vec2 uv = shadow_clip_pos.xy + offset;
        uv /= get_distortion_factor(uv);
        uv = uv * 0.5 + 0.5;

        shadow += texture(shadowtex1, vec3(uv, shadow_screen_pos.z));
    }

    float rcp_steps = rcp(float(step_count));

    // sharpening for small penumbra sizes
    float sharpening_threshold
        = 0.4 * max0((min_filter_radius - penumbra_size) / min_filter_radius);
    shadow = linear_step(
        sharpening_threshold,
        1.0 - sharpening_threshold,
        shadow * rcp_steps
    );

    return shadow * color;
}

vec3 get_filtered_shadows(
    vec3 scene_pos,
    vec3 flat_normal,
    float skylight,
    float cloud_shadows,
    float sss_amount,
    inout float distance_fade,
    inout float sss_depth
) {
    sss_depth = 0.0;

    float NoL = dot(flat_normal, light_dir);

    vec3 bias = get_shadow_bias(scene_pos, flat_normal, NoL, skylight);

    // Light leaking prevention from Complementary Reimagined, used with
    // permission
    vec3 edge_factor
        = 0.1 - 0.2 * fract(scene_pos + cameraPosition + flat_normal * 0.01);
    edge_factor -= edge_factor * skylight;

#ifdef PIXELATED_SHADOWS
    // Snap position to the nearest block texel
    const float pixel_scale = float(PIXELATED_SHADOWS_RESOLUTION);
    scene_pos = scene_pos + cameraPosition;
    scene_pos = floor(scene_pos * pixel_scale + 0.01) * rcp(pixel_scale)
        + (0.5 / pixel_scale);
    scene_pos = scene_pos - cameraPosition;
#endif

    vec3 shadow_view_pos
        = transform(shadowModelView, scene_pos + bias + edge_factor);
    vec3 shadow_clip_pos = project_ortho(shadowProjection, shadow_view_pos);
    vec3 shadow_screen_pos = distort_shadow_space(shadow_clip_pos) * 0.5 + 0.5;

    distance_fade = get_shadow_distance_fade(scene_pos, shadow_screen_pos);

    if (distance_fade >= 1.0) {
        return vec3(1.0);
    }

    float dither = texelFetch(noisetex, ivec2(gl_FragCoord.xy) & 511, 0).b;
    dither = r1(frameCounter, dither);

    // Soft sun terminator: as a face tips past the sun, fade the sunlight smoothly over
    // this NoL range instead of cutting the whole face to black in one step (the snap as
    // the sun's azimuth crosses the noon zenith). Applied to every lit return below.
    float terminator
        = smoothstep(-SUN_TERMINATOR_SOFTNESS, 0.5 * SUN_TERMINATOR_SOFTNESS, NoL);

#ifdef SHADOW_VPS
    vec2 blocker_search_result
        = blocker_search(scene_pos, dither, sss_amount > eps);

    sss_depth = blocker_search_result.y;

    if (NoL < -SUN_TERMINATOR_SOFTNESS) {
        return vec3(0.0); // fully past the terminator (sss_depth already measured)
    }
    if (blocker_search_result.x < eps) {
        return vec3(terminator); // no occluders => lit, faded across the terminator
    }

    float penumbra_size = 16.0 * SHADOW_PENUMBRA_SCALE
        * (shadow_screen_pos.z - blocker_search_result.x)
        / blocker_search_result.x;
    penumbra_size
        *= 5.0 - 4.0 * cloud_shadows; // Increase penumbra radius inside cloud
                                      // shadows, nice overcast look
    penumbra_size = min(penumbra_size, SHADOW_BLOCKER_SEARCH_RADIUS);
    penumbra_size *= shadowProjection[0].x;
#else
    float penumbra_size
        = sqrt(0.5) * shadow_map_pixel_size * SHADOW_PENUMBRA_SCALE;

    // Increase blur radius to approximate subsurface scattering
    penumbra_size *= 1.0 + 7.0 * sss_amount;
#endif

#ifdef SHADOW_COLOR
    // Calculate position without light leaking fix applied, for colored shadow
    // Applying light leaking fix to translucent shadows causes artifacts on
    // water caustics
    vec3 shadow_view_pos_translucent
        = transform(shadowModelView, scene_pos + bias);
    vec3 shadow_clip_pos_translucent
        = project_ortho(shadowProjection, shadow_view_pos_translucent);
    vec3 shadow_screen_pos_translucent
        = distort_shadow_space(shadow_clip_pos_translucent) * 0.5 + 0.5;
#endif

#ifdef SHADOW_PCF
    vec3 shadow = shadow_pcf(
        shadow_screen_pos,
        shadow_clip_pos,
#ifdef SHADOW_COLOR
        shadow_screen_pos_translucent,
        shadow_clip_pos_translucent,
#endif
        penumbra_size,
        dither
    );
#else
    vec3 shadow = shadow_basic(shadow_screen_pos);
#endif

    return shadow * terminator;
}
#endif

#endif // INCLUDE_LIGHTING_SHADOWS
