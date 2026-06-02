#if !defined INCLUDE_LIGHTING_SHADOWS_COMMON
#define INCLUDE_LIGHTING_SHADOWS_COMMON

// Fade from close shadows (shadow maps) to distant shadows (lightmap or SSRT)
float get_shadow_distance_fade(vec3 scene_pos, vec3 shadow_screen_pos) {
    float effective_shadow_distance = min(shadowDistance, far);
    return linear_step(
        0.1,
        1.0,
        pow32(
            max(max_of(abs(shadow_screen_pos.xy * 2.0 - 1.0)),
                length_squared(scene_pos) * rcp(sqr(effective_shadow_distance)))
        )
    );
}

// Fake, lightmap-based shadows for outside of the shadow range or when shadows
// are disabled
float get_lightmap_shadows(float skylight) {
    return smoothstep(13.5 / 15.0, 14.5 / 15.0, skylight);
}

// Prevents light leaking in caves by cancelling out sunlight in very low
// skylight.
// Light-leak fix (mode 2): in addition to
// the fragment's own skylight, fold in the player's smoothed sky exposure
// (eye_skylight) so that stray sunlight is killed while you are deep inside a
// huge cave - even beyond the shadow distance, where the shadow map can't help.
// eye_skylight is passed in (rather than read as a global) so this header still
// compiles in the translucent/DH programs that don't declare that uniform.
float get_lightmap_light_leak_prevention(float skylight, float eye_skylight) {
    // Entities (incl. the player model in 3rd person) can report a higher
    // skylight than the dark cave terrain around them, which let directional sun
    // leak onto them underground. Cap the fragment's skylight to the player's
    // own sky exposure so that can't happen. On the surface eye_skylight is high
    // => no-op; deep in caves terrain skylight is already ~0 => unaffected; only
    // anomalously-bright fragments (entities) get pulled down.
    skylight = min(skylight, eye_skylight + 0.2);
    return clamp01(pow(eye_skylight + skylight, 2.0));
}

#endif
