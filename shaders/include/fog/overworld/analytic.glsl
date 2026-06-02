#if !defined INCLUDE_FOG_AIR_FOG_ANALYTIC
#define INCLUDE_FOG_AIR_FOG_ANALYTIC

#include "/include/fog/overworld/constants.glsl"
#include "/include/misc/lod_mod_support.glsl"
#include "/include/sky/atmosphere.glsl"
#include "/include/utility/phase_functions.glsl"

vec2 air_fog_analytic_airmass(
    vec3 ray_origin_world,
    vec3 ray_direction_world,
    float ray_length
) {
    // Integral of density function with respect to t

    const vec2 mul = -rcp(air_fog_falloff_half_life);
    const vec2 add = -mul * air_fog_falloff_start;

    vec2 a = ray_origin_world.y * mul + add;
    vec2 p1 = exp2(ray_length * ray_direction_world.y * mul + a);
    vec2 p2 = exp2(a);

    return clamp(
               (p1 - p2) * rcp(log(2.0) * mul * ray_direction_world.y),
               0.0,
               ray_length
           )
        * (0.5 * OVERWORLD_FOG_INTENSITY);
}

mat2x3 air_fog_analytic(
    vec3 ray_origin_world,
    vec3 ray_end_world,
    bool sky,
    float skylight,
    float shadow
) {
#ifdef LOD_MOD_ACTIVE
    float fog_end = float(lod_render_distance);
#else
    float fog_end = far;
#endif

    vec3 ray_direction_world;
    float ray_length;
    length_normalize(
        ray_end_world - ray_origin_world,
        ray_direction_world,
        ray_length
    );
    ray_length = sky ? fog_end : ray_length;

    vec2 airmass = air_fog_analytic_airmass(
        ray_origin_world,
        ray_direction_world,
        ray_length
    );

    // Bedrock Fog: pin the mie coefficient (see raymarched.glsl) so the locked
    // fog's brightness is time-static too (rayleigh has no time-of-day factor).
    vec3 fog_mie_scat = fog_params.mie_scattering_coeff;
    vec3 fog_mie_ext = fog_params.mie_extinction_coeff;
#ifdef BEDROCK_FOG_COLOR_LOCK
    fog_mie_scat = vec3(0.00135);
    fog_mie_ext = vec3(0.0015);
#endif

    vec3 optical_depth = fog_params.rayleigh_scattering_coeff * airmass.x
        + fog_mie_ext * airmass.y;
    vec3 transmittance = exp(-optical_depth);
    vec3 scattering_integral = (1.0 - transmittance) / max(optical_depth, eps);

    vec3 rayleigh_scattering = scattering_integral * airmass.x
        * fog_params.rayleigh_scattering_coeff;
    vec3 mie_scattering
        = scattering_integral * airmass.y * fog_mie_scat;

    float LoV = dot(ray_direction_world, light_dir);
    float mie_phase = 0.7 * henyey_greenstein_phase(LoV, 0.5)
        + 0.3 * henyey_greenstein_phase(LoV, -0.2);

    /*
    // Single scattering
    vec3 scattering  = light_color * (light_sun * vec2(isotropic_phase,
    mie_phase)); scattering += ambient_color * (light_sky *
    vec2(isotropic_phase));
    /*/
    // Multiple scattering
    vec3 scattering = vec3(0.0);
    float scatter_amount = 1.0;
    float anisotropy = 1.0;

    // Bedrock Fog Colour Lock (see raymarched.glsl) - keep the analytic fog
    // (used when VL is off) consistent with the volumetric fog: locked 24/7.
    vec3 fog_ambient_color = ambient_color;
#ifdef BEDROCK_FOG_COLOR_LOCK
    fog_ambient_color = pow(
                            vec3(
                                BEDROCK_FOG_COLOR_R,
                                BEDROCK_FOG_COLOR_G,
                                BEDROCK_FOG_COLOR_B
                            ),
                            vec3(2.2)
                        )
        * (BEDROCK_FOG_BRIGHTNESS * 2.5);
#endif

    // Lock the direct / god-ray colour too (see raymarched.glsl).
    vec3 fog_light_color = light_color;
#ifdef BEDROCK_FOG_COLOR_LOCK
    fog_light_color = fog_ambient_color;
#endif

    scattering += 2.0 * (rayleigh_scattering + mie_scattering) * isotropic_phase
        * fog_ambient_color;

    for (int i = 0; i < 4; ++i) {
        float mie_phase = 0.7 * henyey_greenstein_phase(LoV, 0.5 * anisotropy)
            + 0.3 * henyey_greenstein_phase(LoV, -0.2 * anisotropy);

        scattering += scatter_amount
            * (rayleigh_scattering * isotropic_phase
               + mie_scattering * mie_phase)
            * fog_light_color * (1.0 - 0.9 * rainStrength) * shadow;

        scatter_amount *= 0.5;
        anisotropy *= 0.7;
    }
    //*/

    scattering *= max(skylight, eye_skylight);
    scattering *= clamp01(1.0 - blindness - darknessFactor);

    // Artifically brighten fog in the early morning and evening (looks nice)
    float evening_glow
        = 0.75 * linear_step(0.05, 1.0, exp(-300.0 * sqr(sun_dir.y + 0.02)));
#ifdef BEDROCK_FOG_COLOR_LOCK
    evening_glow = 0.0; // keep the locked fog fully time-static
#endif
    scattering += scattering * evening_glow;

#ifdef BEDROCK_FOG_COLOR_LOCK
    // Final safety net: pin the fog HUE to the locked tint (see raymarched.glsl).
    vec3 locked_tint = pow(
        vec3(BEDROCK_FOG_COLOR_R, BEDROCK_FOG_COLOR_G, BEDROCK_FOG_COLOR_B),
        vec3(2.2)
    );
    locked_tint *= rcp(
        max(dot(locked_tint, vec3(0.2126, 0.7152, 0.0722)), eps)
    );
    scattering = locked_tint * dot(scattering, vec3(0.2126, 0.7152, 0.0722));
    // Neutralise the transmittance hue too (scene seen through the fog).
    transmittance = vec3(dot(transmittance, vec3(0.2126, 0.7152, 0.0722)));
#endif

    return mat2x3(max0(scattering), max0(transmittance));
}

// ----------------------------------------------------------------------------
//   Atmospheric Haze (ported from Eclipse)
//
//   A SEPARATE, additive aerial-perspective term. Photon's normal air fog is
//   capped to a vertical volume (air_fog_volume_top = 320) and dies within
//   ~30 blocks of sea level, so it can never reach high terrain. This term uses
//   huge scale heights (like Eclipse's 8000/1200), so it stays dense well above
//   Y1000 and gives distant mountains their bluish "depth" at any altitude.
//   Controlled by ATMOSPHERIC_HAZE_DENSITY; 0 => exact no-op (does not touch the
//   normal fog). Applied to terrain regardless of VL (see c1_blend_layers).
// ----------------------------------------------------------------------------

vec2 air_haze_airmass(
    vec3 ray_origin_world,
    vec3 ray_direction_world,
    float ray_length
) {
    // Large scale heights (blocks): rayleigh persists very high, mie is weak so
    // the haze stays blue. Density is nearly constant from Y -200 up past Y1000.
    const float haze_base_density = 3.0; // internal strength at density 1.0
    const vec2 haze_half_life = vec2(1333.0, 400.0);

    const vec2 mul = -rcp(haze_half_life);
    const vec2 add = -mul * SEA_LEVEL;

    vec2 a = ray_origin_world.y * mul + add;
    vec2 p1 = exp2(ray_length * ray_direction_world.y * mul + a);
    vec2 p2 = exp2(a);

    vec2 airmass = clamp(
        (p1 - p2) * rcp(log(2.0) * mul * ray_direction_world.y),
        0.0,
        ray_length
    );

    // Keep it mostly rayleigh (blue); a little mie for sun-direction glow.
    // The 0.1 remaps the user slider (now 0.0-1.0) onto the useful old 0.0-0.10
    // range (anything above old 0.10 was way too thick).
    return airmass * vec2(1.0, 0.15)
        * (haze_base_density * ATMOSPHERIC_HAZE_DENSITY * 0.1);
}

mat2x3 air_haze_analytic(
    vec3 ray_origin_world,
    vec3 ray_end_world,
    bool sky,
    float skylight,
    float shadow
) {
    // Leave the sky to Photon's own atmosphere; the haze only tints terrain.
    // Density 0 is a true no-op so it never disturbs the normal fog.
    if (sky || ATMOSPHERIC_HAZE_DENSITY < eps) {
        return mat2x3(vec3(0.0), vec3(1.0));
    }

    vec3 ray_direction_world;
    float ray_length;
    length_normalize(
        ray_end_world - ray_origin_world,
        ray_direction_world,
        ray_length
    );

    vec2 airmass = air_haze_airmass(
        ray_origin_world,
        ray_direction_world,
        ray_length
    );
    vec3 optical_depth = fog_params.rayleigh_scattering_coeff * airmass.x
        + fog_params.mie_extinction_coeff * airmass.y;
    vec3 transmittance = exp(-optical_depth);
    vec3 scattering_integral = (1.0 - transmittance) / max(optical_depth, eps);

    vec3 rayleigh_scattering = scattering_integral * airmass.x
        * fog_params.rayleigh_scattering_coeff;
    vec3 mie_scattering
        = scattering_integral * airmass.y * fog_params.mie_scattering_coeff;

    float LoV = dot(ray_direction_world, light_dir);

    vec3 scattering = vec3(0.0);
    float scatter_amount = 1.0;
    float anisotropy = 1.0;

    // Haze uses the natural sky ambient (blue day / golden sunset / dim night).
    scattering += 2.0 * (rayleigh_scattering + mie_scattering) * isotropic_phase
        * ambient_color;

    for (int i = 0; i < 4; ++i) {
        float mie_phase = 0.7 * henyey_greenstein_phase(LoV, 0.5 * anisotropy)
            + 0.3 * henyey_greenstein_phase(LoV, -0.2 * anisotropy);

        scattering += scatter_amount
            * (rayleigh_scattering * isotropic_phase
               + mie_scattering * mie_phase)
            * light_color * (1.0 - 0.9 * rainStrength) * shadow;

        scatter_amount *= 0.5;
        anisotropy *= 0.7;
    }

    scattering *= max(skylight, eye_skylight);
    scattering *= clamp01(1.0 - blindness - darknessFactor);

    return mat2x3(max0(scattering), max0(transmittance));
}

#endif // INCLUDE_FOG_AIR_FOG_ANALYTIC
