#if !defined INCLUDE_LIGHTING_DIFFUSE_LIGHTING
#define INCLUDE_LIGHTING_DIFFUSE_LIGHTING

#include "/include/lighting/bsdf.glsl"
#include "/include/lighting/colors/blocklight_color.glsl"
#include "/include/misc/end_lighting_fix.glsl"
#include "/include/surface/material.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/utility/phase_functions.glsl"
#ifdef MC_GL_RENDERER_INTEL
#include "/include/utility/spherical_harmonics_fallback.glsl"
#else
#include "/include/utility/spherical_harmonics.glsl"
#endif
#ifdef COLORED_LIGHTS
#include "/include/lighting/lpv/blocklight.glsl"
#endif

#ifdef HANDHELD_LIGHTING
#include "/include/lighting/handheld_lighting.glsl"
#endif

#if !defined WORLD_OVERWORLD
#undef CLOUD_SHADOWS
#endif

#if defined PHOTONICS_DIFFUSE
#include "/photonics/ph_samplers.glsl"

#ifndef PHOTONICS_RESTIR_COMBINED_GI
uniform sampler2D radiosity_indirect;
#endif

#endif

const float sss_density = 14.0;
const float sss_scale = 5.0 * SSS_INTENSITY;
const float night_vision_scale = 1.5;
const float metal_diffuse_amount
    = 0.5; // Scales diffuse lighting on metals, ideally this would be zero but
           // purely specular metals don't play well with SSR

float get_blocklight_falloff(float blocklight, float skylight, float ao) {
    float falloff = pow8(blocklight) + 0.18 * sqr(blocklight)
        + 0.16 * dampen(blocklight); // Base falloff
    falloff *= mix(
        cube(ao),
        1.0,
        clamp01(falloff)
    ); // Stronger AO further from the light source
    falloff *= mix(
        1.0,
        ao * dampen(abs(cos(2.0 * frameTimeCounter))) * 0.67 + 0.2,
        darknessFactor
    ); // Pulsing blocklight with darkness effect
    falloff *= 1.0 - 0.2 * time_noon * skylight
        - 0.2 * skylight; // Reduce blocklight intensity in daylight
    falloff += min(
        2.7 * pow12(blocklight),
        0.9
    ); // Strong highlight around the light source, visible even in the daylight
    falloff *= smoothstep(
        0.0,
        0.125,
        blocklight
    ); // Ease transition at edge of lightmap

    return falloff;
}

float get_skylight_falloff(float skylight) {
#if defined WORLD_OVERWORLD
    float gentle = sqr(skylight);
    // Steeper falloff: ambient drops hard below full-sky exposure, so shadowed
    // and occluded areas go much darker while open full-sky stays the same (both
    // curves = 1 at skylight 1.0; steep is ~1/3 at 0.5). SHADOW_DARKNESS dials
    // gentle -> steep, deepening near AND far shadows together.
    float steep_low = (2.0 * pow(skylight, 15.0) + gentle) * (1.0 / 3.0);
    float steep = mix(steep_low, gentle, smoothstep(0.5, 0.9, skylight));
    // SHADOW_DARKNESS spans two halves so the slider reaches past the old maximum:
    //   0.0 -> gentle, 0.5 -> steep, 1.0 -> steep^2 (deepest). Full-sky (skylight 1)
    //   stays 1.0 throughout, so only partly-occluded ambient deepens.
    float d = 2.0 * SHADOW_DARKNESS;
    float falloff = mix(gentle, steep, min(d, 1.0));
    return mix(falloff, steep * steep, clamp01(d - 1.0));
#else
    return 1.0;
#endif
}

#ifdef SHADOW_VPS
vec3 sss_approx(
    vec3 albedo,
    float sss_amount,
    float sheen_amount,
    float sss_depth,
    float LoV,
    float shadow
) {
    // Transmittance-based SSS
    if (sss_amount < eps) {
        return vec3(0.0);
    }

    vec3 coeff = albedo * inversesqrt(dot(albedo, luminance_weights) + eps);
    coeff = 0.75 * clamp01(coeff);
    coeff = (1.0 - coeff) * sss_density / sss_amount;

    float phase
        = mix(isotropic_phase, henyey_greenstein_phase(-LoV, 0.7), 0.33);

    vec3 sss = sss_scale * phase * exp2(-coeff * sss_depth) * dampen(sss_amount)
        * pi;

#ifdef SSS_SHEEN
    vec3 sheen = (0.8 * SSS_INTENSITY) * rcp(albedo + eps)
        * exp2(-1.0 * coeff * sss_depth) * henyey_greenstein_phase(-LoV, 0.5)
        * linear_step(-0.8, -0.2, -LoV);
    sss += sheen * sheen_amount;
#endif

    return sss;
}
#else
vec3 sss_approx(
    vec3 albedo,
    float sss_amount,
    float sheen_amount,
    float sss_depth,
    float LoV,
    float shadow
) {
    // Blur-based SSS
    float sss = 0.06 * sss_scale * pi;
    vec3 sheen = 0.8 * rcp(albedo + eps) * henyey_greenstein_phase(-LoV, 0.5)
        * linear_step(-0.8, -0.2, -LoV) * shadow;

    return sss + sheen * sheen_amount;
}
#endif

vec3 get_block_lighting(
    vec3 scene_pos,
    vec3 flat_normal,
    vec2 light_levels,
    float ao,
    float directional_lighting
) {
    vec3 lighting = vec3(0.0f);

    float blocklight_falloff
        = get_blocklight_falloff(light_levels.x, light_levels.y, ao);
    vec3 mc_blocklight = (blocklight_falloff * directional_lighting)
        * (blocklight_scale * blocklight_color);

#ifdef COLORED_LIGHTS
    lighting += get_lpv_blocklight(
        scene_pos,
        flat_normal,
        mc_blocklight,
        ao * directional_lighting
    );
#else
    lighting += mc_blocklight;
#endif

#ifdef HANDHELD_LIGHTING
    lighting += get_handheld_lighting(scene_pos, ao);
#endif

    return lighting;
}

// sss_transmission_sky is defined further down (after sss_transmission_sun);
// forward-declared so get_sky_lighting's LoD ambient branch can call it.
vec3 sss_transmission_sky(vec3 albedo, float sky_sss, float sss_amount);

vec3 get_sky_lighting(
    Material material,
    vec3 bent_normal,
    vec2 light_levels,
    float ao,
    float ambient_sss,
    float directional_lighting,
    bool is_near_field,
    float distant_fade
) {
    vec3 lighting = vec3(0.0f);

#if defined WORLD_OVERWORLD && defined PROGRAM_DEFERRED4 && defined SH_SKYLIGHT
#ifdef MC_GL_RENDERER_INTEL
    sh3 sky_sh_compat;
    for (uint band = 0u; band < 3u; ++band) {
        sky_sh_compat.f1[band] = sky_sh[band];
        sky_sh_compat.f2[band] = sky_sh[band + 3u];
        sky_sh_compat.f3[band] = sky_sh[band + 6u];
    }
    vec3 skylight = sh_evaluate_irradiance(sky_sh_compat, bent_normal, ao);
#else
    vec3 skylight = sh_evaluate_irradiance(sky_sh, bent_normal, ao);
#endif
    skylight = mix(skylight_up, skylight, sqr(light_levels.y));
#else
    vec3 skylight = ambient_color * ao;
    vec3 skylight_up = skylight;
#endif

    // Skylight SSS - HARD fork. Near-field terrain uses the shadow-map ambient SSS;
    // far-field terrain uses the screenspace transmission model, so the far-field
    // path carries ZERO shadow-map SSS.
    if (is_near_field) {
        skylight = mix(skylight, 0.5 * skylight_up * ao, material.sss_amount);
        skylight += ambient_sss * skylight_up * material.sss_amount * 2.0;
    } else {
        float sky_sss = clamp01(ambient_sss + 0.5 * sqr(light_levels.y));
        skylight += sss_transmission_sky(
                        material.albedo, sky_sss, material.sss_amount)
            * skylight_up * (AMBIENT_SSS_BRIGHTNESS * light_levels.y);
    }

#if defined WORLD_NETHER
    // Brighten + desaturate nether ambient
    skylight = 16.0 * directional_lighting
        * mix(skylight, vec3(dot(skylight, luminance_weights_rec2020)), 0.5);
#endif

#if defined WORLD_OVERWORLD && defined PROGRAM_DEFERRED4 && defined SH_SKYLIGHT
    // Distant ambient dimming - far-field terrain ONLY. Shaded faces out there are
    // lit by ambient alone, so lowering it deepens the lit-vs-shadow contrast of
    // distant mountains. Gated on is_near_field (NOT distance) so near-field terrain
    // is never touched, even at the far edge of the map.
    float distant_ambient
        = is_near_field ? 1.0 : mix(1.0, DISTANT_AMBIENT_I, distant_fade);
    // Night ambient dimming - fades the sky AMBIENT (the shadow fill) darker as the
    // sun drops below the horizon, deepening night shadows toward NIGHT_AMBIENT_I.
    // The direct moon term is untouched, so moonlit faces stay bright while shadowed
    // ones go dark. Daytime (sun above horizon) is a no-op.
    float night_ambient = mix(
        1.0, NIGHT_AMBIENT_I, 1.0 - smoothstep(-0.25, 0.0, sun_dir.y));
    lighting += skylight * get_skylight_falloff(light_levels.y)
        * distant_ambient * night_ambient;
#else
    lighting += skylight * get_skylight_falloff(light_levels.y);
#endif

    return lighting;
}

// Sharp forward-scattering peak when looking towards the light
float sss_forward_phase(float light_pos) {
    float phase_curve = 1.0 - light_pos;
    float phase = exp2(sqrt(phase_curve) * -25.0);
    return phase + exp(phase_curve * -10.0) * 0.5;
}

// Far-field sunlight transmission. Keyed to the SSRT-measured light path
// (sss_depth): full strength where it enters at the sunlit surface, dying within
// a fraction of a block, so a shadowed face shows a bright band along its sunlit
// edge rather than a whole-face glow. The short screen-space ray (ss_occlusion)
// sharpens that band per-pixel: the deeper a point sits behind its own
// silhouette, the more the transmission is crushed. sss_amount sets the
// penetration depth only. Near-field terrain uses sss_approx (the near-field
// model) instead - see get_diffuse_lighting's hard fork.
vec3 sss_transmission_sun(
    vec3 albedo,
    float sss_depth,
    float sss_amount,
    float light_pos,
    float ss_occlusion,
    float distant_sss
) {
    if (sss_amount < 0.01) {
        return vec3(0.0);
    }

    float scattering = sss_depth * SSS_DENSITY;
    float density = 1e-6 + sss_amount * 1.5;

    float scatter_depth = max0(1.0 - scattering / density);
    scatter_depth *= exp(-7.0 * (1.0 - scatter_depth));

    // Crush the transmission where the screen-space ray towards the light is
    // buried in geometry. Near the lit edge (ray escapes, low occlusion) the
    // measured path and the ray share authority, keeping the band bright - but
    // a DEEPLY buried ray always wins, so a thick occluder the ray can see but
    // the depth path under-measured can't glow through.
    float ss_shadows = exp(-7.0 * ss_occlusion) * 0.7;
    // Escape weight is constant-scaled (reference parity). Folding the
    // occlusion into the weight itself snapped it to zero on the FIRST buried
    // step - a two-level squarewave across terrace rows on distant SSS
    // terrain (grass/leaf LoD banding).
    scatter_depth *= mix(
        ss_shadows,
        1.0,
        0.5 * scatter_depth * distant_sss
    );

    // Light that travels deeper takes on the material's colour, shifted warm
    vec3 absorbed = exp(
        max0(dot(albedo, luminance_weights) - albedo * vec3(1.0, 1.1, 1.2))
        * (-20.0 * SSS_ABSORBANCE)
    );
    vec3 scatter = scatter_depth * mix(absorbed, vec3(1.0), scatter_depth);

    return scatter * (1.0 + 20.0 * sss_forward_phase(light_pos));
}

// Far-field ambient SSS: skylight scattered through thin materials, a soft glow
// strongest where geometry stands open to the sky. Near-field terrain uses
// the shadow-map ambient SSS in get_sky_lighting instead.
vec3 sss_transmission_sky(vec3 albedo, float sky_sss, float sss_amount) {
    float scatter_depth = pow(sky_sss, 3.5);
    scatter_depth = 1.0 - pow4(1.0 - scatter_depth) * (1.0 - scatter_depth);

    vec3 absorbed = exp(
        max0(dot(albedo, luminance_weights) - albedo * vec3(1.0, 1.1, 1.2))
        * (-20.0 * SSS_ABSORBANCE)
    );

    return (scatter_depth * sss_amount)
        * mix(absorbed, vec3(1.0), scatter_depth);
}

vec3 get_diffuse_lighting(
    Material material,
    vec3 scene_pos,
    vec3 normal,
    vec3 flat_normal,
    vec3 bent_normal,
    vec3 shadows,
    vec2 light_levels,
    float ao,
    float ambient_sss,
    float sss_depth,
    bool is_near_field,
    float sss_screen_occlusion,
#ifdef CLOUD_SHADOWS
    float cloud_shadows,
#endif
    float sss_distance_fade, // view-distance SSS trust fade (0 near, 1 far)
#ifdef PHOTONICS_DIFFUSE
    bool is_lod,
#endif
    float NoL,
    float NoV,
    float NoH,
    float LoV
) {
#if defined PROGRAM_GBUFFERS_WATER
    // Small optimization, don't calculate diffuse lighting when albedo is 0 (eg
    // water)
    if (max_of(material.albedo) < eps) {
        return vec3(0.0);
    }
#endif

    vec3 lighting = vec3(0.0);

    // Arbitrary directional shading to make faces easier to distinguish
    float directional_lighting
        = (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y));
    // Near-field ambient-SSS boost: near-field terrain ONLY. Far-field runs the
    // screenspace SSS model and must carry no near-field SSS.
    if (is_near_field) {
        // Sky-access gated, like the rim and the sun SSS: a block the sky can't reach gets no
        // ambient-SSS boost, so SSS can't amplify its glow underground (deep caverns). Without
        // this, the boost rides into BOTH the skylight and the block-light terms below.
        directional_lighting += 2.0 * ambient_sss * material.sss_amount
            * linear_step(0.1, 0.2, light_levels.y); // HARD floor: 0 below skylight 0.1
    }

    // Negative SSS depth => SSS blocked by occluder (SSRT SSS)
    bool sss_blocked = sss_depth < 0.0 || light_levels.y < 0.1;
    sss_depth = max0(sss_depth);

#if defined WORLD_OVERWORLD || defined WORLD_END

    // Sunlight/moonlight

#if defined SHADOW || defined SHADOW_SSRT
    // The SSS diffuse-reduction (1 - 0.5*sss_amount) is the near-field model -
    // near-field terrain only; far-field keeps full diffuse (float(...) = 0).
    vec3 diffuse = vec3(
        lift(max0(NoL), 0.25 * rcp(SHADING_STRENGTH))
        * (1.0 - 0.5 * material.sss_amount * float(is_near_field))
    );

// Disable bounced lighting with Photonics
#if defined PHOTONICS_DIFFUSE
#define DO_BOUNCED_LIGHTING is_lod
#else
#define DO_BOUNCED_LIGHTING true
#endif

    vec3 bounced = vec3(0.0);
    if (DO_BOUNCED_LIGHTING) {
        bounced = 0.033 * (1.0 - shadows) * (1.0 - 0.1 * max0(normal.y))
            * pow1d5(ao + eps) * pow4(light_levels.y) * BOUNCED_LIGHT_I;
    }

#ifdef AO_IN_SUNLIGHT
    // Near field keeps the strong sqr(ao) curve. The far model uses the
    // reference curve with a 0.3 floor: the LoD spiral SSAO legitimately
    // carries scene-scale occlusion (foreground shapes shading far walls),
    // which sqr() amplifies into visible dark imprints ("ghosting"); the
    // floored curve renders the same signal as subtle contact shading.
    diffuse *= is_near_field ? sqr(ao) : (ao * 0.7 + 0.3);
#endif

    // ONE model per call: this evaluates either the near-field (shadow-map) OR the far-field
    // (screenspace) SSS, selected by is_near_field - a single call is never itself a
    // blend. d4 calls get_diffuse_lighting once per pixel with the dither-PICKED model
    // and TAA blends the near<->far transition (the MID field). See d4 "TERRAIN LIGHTING".
    if (is_near_field) {
        // Near-field SSS (shadow-map). Real measured light path.
        vec3 sss = sss_approx(
                       material.albedo,
                       material.sss_amount,
                       material.sheen_amount,
                       sss_depth,
                       LoV,
                       shadows.x
                   )
            * float(!sss_blocked);

#ifdef SHADOW_VPS
        lighting += diffuse * shadows + bounced + sss;
#else
        lighting += mix(diffuse, sss, material.sss_amount) * shadows + bounced;
#endif
    } else {
        // Far-field SSS (screenspace). sss_depth is the SSRT measurement (never the
        // shadow-map probe); the screen-space occlusion ray shapes it per-pixel so
        // the transmission band hugs sun-grazed edges and is crushed on buried
        // faces. Gated only by the leak check - no view-dependent term, so the
        // far-field transmission reads the same from any camera angle.
        float sss_distance_trust = 1.0 - clamp01(sss_distance_fade);
        vec3 sss = sss_transmission_sun(
                       material.albedo,
                       sss_depth,
                       material.sss_amount,
                       clamp01(-LoV),
                       sss_screen_occlusion,
                       sss_distance_trust
                   )
            * float(!sss_blocked);

        // Transmission shows exactly where direct light doesn't reach: the two
        // crossfade so a face is never lit by both at once.
        // NOTE: `diffuse` (shared shaping incl. AO_IN_SUNLIGHT) is safe here
        // ONLY while the LoD AO source is the band-free spiral SSAO in d3 -
        // a horizon-AO output multiplied into this term printed terrace
        // striping onto every sunlit LoD face.
        vec3 sunlit = diffuse * shadows;
        lighting += sunlit + sss * clamp01(1.0 - sunlit) + bounced;
    }
#else
    // Simple shading for when shadows are disabled
    vec3 sss = 0.08 * sss_scale * pi
        + 0.5 * material.sheen_amount * rcp(material.albedo + eps)
            * henyey_greenstein_phase(-LoV, 0.5)
            * linear_step(-0.8, -0.2, -LoV);

    vec3 diffuse
        = vec3(lift(max0(NoL), 0.5 * rcp(SHADING_STRENGTH)) * 0.6 + 0.4)
        * (shadows * 0.8 + 0.2);
    diffuse = diffuse + max0(sss * lift(material.sss_amount, 5.0));
    diffuse *= 1.0 * (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y));
    diffuse *= ao * pow4(light_levels.y) * (dampen(light_dir.y) * 0.5 + 0.5);

    lighting += diffuse;
#endif

    lighting *= light_color;

#ifdef CLOUD_SHADOWS
    lighting *= cloud_shadows;
#endif
#endif

    // Skylight

#if defined PHOTONICS_DIFFUSE
    if (is_lod) {
        lighting += get_sky_lighting(
            material,
            bent_normal,
            light_levels,
            ao,
            ambient_sss,
            directional_lighting,
            is_near_field,
            clamp01(sss_distance_fade)
        );
    } else {
// When combined gi is enabled
// Photonics includes gi in the result of sample_photonics_direct
#ifndef PHOTONICS_RESTIR_COMBINED_GI
        lighting += texture2D(radiosity_indirect, uv).xyz * SKYLIGHT_I;
#endif
    }

#else
    lighting += get_sky_lighting(
        material,
        bent_normal,
        light_levels,
        ao,
        ambient_sss,
        directional_lighting,
        is_near_field,
        clamp01(sss_distance_fade)
    );
#endif

    // Far-field light-source boost at night. Distant torches/lanterns (their emission
    // AND the warm blocklight glow they cast) pump out more light once the sun sets, so
    // far-off villages read like the reference. FAR-FIELD ONLY - near-field is
    // byte-identical - and a smooth dusk ramp, so daytime is untouched.
#if defined PROGRAM_DEFERRED4 && defined WORLD_OVERWORLD
    float far_night_light = is_near_field
        ? 1.0
        : mix(1.0, NIGHT_EMISSION_I, 1.0 - smoothstep(-0.25, 0.0, sun_dir.y));
#else
    const float far_night_light = 1.0;
#endif

    // Blocklight

#if defined PHOTONICS_DIFFUSE
    if (!is_lod) {
        vec3 blocklight = vec3(0.0f);

        blocklight += sample_photonics_direct(uv);

#ifdef HANDHELD_LIGHTING
        blocklight += sample_photonics_handheld(uv);
#endif

        // BLOCKLIGHT_I is applied in /photonics/modifiers/modify_lights.glsl
        lighting += blocklight * blocklight_scale;
    } else {
        lighting += get_block_lighting(
            scene_pos,
            flat_normal,
            light_levels,
            ao,
            directional_lighting
        );
    }
#else
    lighting += get_block_lighting(
        scene_pos,
        flat_normal,
        light_levels,
        ao,
        directional_lighting
    ) * far_night_light;
#endif

    // Emissive blocks. far_night_light (computed above) boosts far-field light sources
    // at night; it is 1.0 for near-field and daytime, so this is otherwise unchanged.
    lighting += material.emission * emission_scale * far_night_light;

#if defined WORLD_OVERWORLD
    // Cave lighting

    lighting += 0.15 * CAVE_LIGHTING_I * directional_lighting * ao
        * (1.0 - light_levels.y * light_levels.y)
        * (1.0 - 0.7 * darknessFactor);
    lighting += nightVision * night_vision_scale * directional_lighting * ao;
#endif

    return max0(lighting) * material.albedo * rcp_pi
        * mix(1.0, metal_diffuse_amount, float(material.is_metal));
}

#endif // INCLUDE_LIGHTING_DIFFUSE_LIGHTING
