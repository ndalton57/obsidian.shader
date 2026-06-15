#if !defined INCLUDE_LIGHTING_SHADOWS_SSRT_SHADOWS
#define INCLUDE_LIGHTING_SHADOWS_SSRT_SHADOWS

#include "/include/lighting/shadows/common.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/sampling.glsl"
#include "/include/utility/space_conversion.glsl"

bool raymarch_shadow(
    sampler2D depth_sampler,
    mat4 projection_matrix,
    mat4 projection_matrix_inverse,
    vec3 ray_origin_screen,
    vec3 ray_origin_view,
    vec3 ray_dir_view,
    bool has_sss,
    float dither,
    out float sss_depth
) {
    const uint step_count = uint(SHADOW_SSRT_STEPS);
    const float step_ratio = 2.0; // geometric sample distribution
    const float z_tolerance = 10.0; // assumed thickness in blocks

    vec3 ray_dir_screen = normalize(
        view_to_screen_space(
            projection_matrix,
            ray_origin_view + ray_dir_view,
            true
        )
        - ray_origin_screen
    );

    float ray_length = min_of(
        abs(sign(ray_dir_screen) - ray_origin_screen)
        / max(abs(ray_dir_screen), eps)
    );
    ray_length = min(
        ray_length,
        max(0.1, exp(-max0(length(ray_origin_view) * 0.025 - 1.0)))
    );

    const float initial_step_scale = step_ratio == 1.0
        ? rcp(float(step_count))
        : (step_ratio - 1.0) / (pow(step_ratio, float(step_count)) - 1.0);
    float step_length = ray_length * initial_step_scale;

    vec3 ray_pos = ray_origin_screen + length(view_pixel_size) * ray_dir_screen;

    bool hit = false;
    bool hit_after_sss = false;
    bool sss_raymarch = has_sss;
    vec3 exit_pos = ray_origin_view;

    for (int i = 0; i < step_count; ++i) {
        step_length *= step_ratio;
        vec3 ray_step = ray_dir_screen * step_length;
        vec3 dithered_pos = ray_pos + dither * ray_step;
        ray_pos += ray_step;

#ifdef LOD_MOD_ACTIVE
        if (dithered_pos.z < 0.0) {
            continue;
        }
#endif
        if (clamp01(dithered_pos) != dithered_pos) {
            break;
        }

        float depth = texelFetch(
                          depth_sampler,
                          ivec2(dithered_pos.xy * view_res * taau_render_scale),
                          0
        )
                          .x;

        float z_ray = screen_to_view_space_depth(
            projection_matrix_inverse,
            dithered_pos.z
        );
        float z_sample
            = screen_to_view_space_depth(projection_matrix_inverse, depth);

        bool inside = depth != 0.0 && depth < dithered_pos.z
            && abs(z_tolerance - (z_ray - z_sample)) < z_tolerance;
        hit = inside || hit;

        if (sss_raymarch) {
            if (!inside) {
                exit_pos = dithered_pos;
                sss_raymarch = false;
            }
        }

        else if (!sss_raymarch) {
            hit_after_sss = inside || hit_after_sss;
            if (hit) {
                break;
            }
        }
    }

    exit_pos = screen_to_view_space(projection_matrix_inverse, exit_pos, true);
    sss_depth = hit_after_sss ? -1.0
                              : max0(distance(ray_origin_view, exit_pos) * 0.2);

    return hit;
}

float get_screen_space_shadows(
    vec2 position_screen_xy,
    vec3 position_view,
    float depth,
#ifdef LOD_MOD_ACTIVE
    float depth_lod,
#endif
    float skylight,
    bool has_sss,
    inout float sss_depth
) {
    // Dithering for ray offset
    float dither = texelFetch(noisetex, ivec2(gl_FragCoord.xy) & 511, 0).b;
    dither = r1(frameCounter, dither);

    // Slightly randomise ray direction to create soft shadows
    vec2 hash = hash2(gl_FragCoord.xy);
    vec3 ray_dir
        = normalize(view_light_dir + 0.03 * uniform_sphere_sample(hash));

#ifdef LOD_MOD_ACTIVE
    // Far-field (Voxy LoD) terrain marches the LoD-only depth buffer at EVERY
    // far-field distance, so the cast shadow comes from LoD geometry alone.
    // Marching the combined buffer (near vanilla + LoD) for the nearest strip
    // would let near vanilla terrain cast onto the LoD - but only within a fixed
    // CAMERA distance (far+64), so that shadow slides forward with the player and
    // drops the moment terrain crosses the strip edge, instead of staying put on
    // the terrain. One buffer at all far-field distances keeps the shadow stable.
    bool hit = raymarch_shadow(
        lod_depth_tex,
        lod_projection_matrix,
        lod_projection_matrix_inverse,
        vec3(position_screen_xy, depth_lod),
        screen_to_view_space(
            lod_projection_matrix_inverse,
            vec3(position_screen_xy, depth_lod),
            true
        ),
        ray_dir,
        has_sss,
        dither,
        sss_depth
    );

    // Thin-surface baseline for the far-field transmission. On thick LoD terrain
    // the shadow march returns -1 (occluded beyond the surface), which would
    // suppress the distant glow entirely; the transmission is instead shaped
    // per-pixel by the screen-space occlusion ray (get_sss_screen_occlusion),
    // which marches the LoD projection clipped to the LoD near/far planes so it
    // reads the same at every far-field distance.
    sss_depth = 0.0;
#else
    bool hit = raymarch_shadow(
        depthtex1,
        gbufferProjection,
        gbufferProjectionInverse,
        vec3(position_screen_xy, depth),
        position_view,
        view_light_dir,
        has_sss,
        dither,
        sss_depth
    );
#endif

    // Light-leak prevention is now applied once to the combined shadow result
    // in d4_deferred_shading (see get_lightmap_light_leak_prevention), so it is
    // intentionally not multiplied in here to avoid darkening twice.
    return float(!hit);
}

// Depth linearisation (swapperlinZ): a screen-space depth in [0,1]
// mapped to a linear fraction for the given near/far. The marched ray depth and
// the sampled depth both go through it, so the thickness test is sized the same
// way at every distance.
float swapperlinZ(float depth, float near_plane, float far_plane) {
    return (2.0 * near_plane)
        / (far_plane + near_plane - depth * (far_plane - near_plane));
}

// Screen-space occlusion towards the light, for far-field subsurface
// transmission. The screen-space occlusion march (its SSS half): march a
// fixed screen-space step from the fragment towards the light against the LoD
// opaque depth and accumulate the distance-weighted fraction of steps buried
// behind geometry. The ray clips and linearises with the LoD projection's own
// planes - dhVoxyNearPlane/dhVoxyFarPlane, exposed as lod_near/lod_far
// (16 / 48000 for Voxy; dhNearPlane/dhFarPlane for DH) - so the occlusion reads
// the same at every far-field distance and camera angle. sss_transmission_sun
// consumes the result to shape the transmission per pixel.
float get_sss_screen_occlusion(
    vec2 position_screen_xy,
    vec3 position_view, // combined projection space
    float depth // combined depth
#ifdef LOD_MOD_ACTIVE
    ,
    bool is_lod,
    float depth_lod // LoD depth, for the LoD-space reconstruction
#endif
) {
    const int step_count = 16;

    float dither = texelFetch(noisetex, ivec2(gl_FragCoord.xy) & 511, 0).b;
    dither = r1(frameCounter, dither);

    // Far-field marches the LoD-only opaque buffer in LoD projection with the
    // LoD near/far planes; near-field stays in combined space.
    mat4 proj = combined_projection_matrix;
    vec3 frag_view = position_view;
    float frag_z = depth;
    float near_plane = combined_near;
    float far_plane = combined_far;
#ifdef LOD_MOD_ACTIVE
    if (is_lod) {
        proj = lod_projection_matrix;
        frag_view = screen_to_view_space(
            lod_projection_matrix_inverse,
            vec3(position_screen_xy, depth_lod),
            true
        );
        frag_z = depth_lod;
        near_plane = lod_near; // dhVoxyNearPlane (16 for Voxy)
        far_plane = lod_far;   // dhVoxyFarPlane (48000 for Voxy)
    }
#endif

    vec3 position = vec3(position_screen_xy, frag_z);

    // Screen-space occlusion ray: prevent it going behind the camera, then a
    // fixed-size screen-space step towards the light.
    float ray_length
        = ((frag_view.z + view_light_dir.z * far_plane * sqrt(3.0)) > -near_plane)
        ? (-near_plane - frag_view.z) / view_light_dir.z
        : far_plane * sqrt(3.0);

    vec3 direction = view_to_screen_space(
                         proj,
                         frag_view + view_light_dir * ray_length,
                         true
                     )
        - position;
    direction /= max(
        max(abs(direction.x) / 0.0005, abs(direction.y) / 0.0005),
        400.0
    );
    direction *= 6.0;

    vec3 ray_pos = position + direction * dither;
    ray_pos += direction * 0.3; // shadow bias against self-intersection

    float sss_distance_scale
        = 1.0 / (1.0 + swapperlinZ(position.z, near_plane, far_plane) * 32.0);
    float distance_weight = 1.0 + length(frag_view) / 150.0;

    float occlusion = 0.0;

    for (int i = 0; i < step_count; ++i) {
        if (clamp01(ray_pos.xy) != ray_pos.xy) {
            break;
        }

        ivec2 sample_texel
            = ivec2(ray_pos.xy * view_res * taau_render_scale);
        float depth_sample;
#ifdef LOD_MOD_ACTIVE
        if (is_lod) {
            depth_sample = texelFetch(lod_depth_tex_solid, sample_texel, 0).x;
        } else
#endif
        {
            depth_sample = texelFetch(combined_depth_tex, sample_texel, 0).x;
        }

        // depth_sample == 0 is an empty LoD texel (sky / no geometry); skip it,
        // else every empty step would falsely register as an occluder.
        if (depth_sample != 0.0 && depth_sample < ray_pos.z) {
            float linear_current
                = swapperlinZ(ray_pos.z, near_plane, far_plane);
            float linear_sample
                = swapperlinZ(depth_sample, near_plane, far_plane);
            float dist
                = abs(linear_sample - linear_current) / linear_current;

            if (dist < sss_distance_scale) {
                occlusion += distance_weight;
            }
        }

        ray_pos += direction;
    }

    return occlusion * rcp(float(step_count));
}

#endif // INCLUDE_LIGHTING_SHADOWS_SSRT_SHADOWS
