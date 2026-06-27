#if !defined INCLUDE_SKY_CLOUDS_SAMPLING
#define INCLUDE_SKY_CLOUDS_SAMPLING

// Sample filtered clouds
vec4 read_clouds_and_aurora(vec2 uv, out float apparent_distance) {
#if defined WORLD_OVERWORLD
    // Soften clouds for new pixels
    float pixel_age
        = texelFetch(colortex12, ivec2(uv * view_res * taau_render_scale), 0).y;

    // Newly revealed pixels (no history yet — e.g. the strip swept in by
    // camera rotation) are read extra-blurred while they re-converge. Keep
    // that ramp short and close to the softness floor: a wide, slow ramp
    // shows as a sharpness seam sweeping across the sky when the camera
    // turns (the previous frame's screen edge).
    float ld = min(CLOUDS_SOFTNESS + 0.75, 2.0)
        * dampen(max0(1.0 - 0.25 * pixel_age));

    // Softness floor: reading the converged cloud buffer at a higher mip
    // gives a soft half-resolution cloud look (mip 1 is the
    // half-res image), hiding the crisp detail the temporal reconstruction
    // would otherwise resolve. 0 = full sharpness.
#ifndef CLOUDS_DEBUG_DECOMPOSE
    ld = max(ld, CLOUDS_SOFTNESS);
#endif

    apparent_distance
        = min_of(textureGather(colortex12, uv * taau_render_scale, 0));
    vec4 result = textureLod(colortex11, uv * taau_render_scale, ld);

    if (LIGHTNING_FLASH_UNIFORM > 0.01) {
        float ambient_scattering
            = texture(colortex12, uv * taau_render_scale).z;
        result.xyz += LIGHTNING_FLASH_UNIFORM * lightning_flash_intensity
            * ambient_scattering;
    }

    result.xyz *= clamp01(1.0 - blindness - darknessFactor);

    return result;
#else
    return vec4(0.0, 0.0, 0.0, 1.0);
#endif
}

#endif // INCLUDE_SKY_CLOUDS_SAMPLING
