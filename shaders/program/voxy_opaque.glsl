#include "/include/global.glsl"
#include "/include/utility/encoding.glsl"
#if defined CHERRY_GROVE_PINK_GRASS && defined WORLD_OVERWORLD
#include "/include/misc/cherry_grove.glsl"
#endif

layout(location = 0) out vec4 gbuffer_data_0;

void voxy_emitFragment(VoxyFragmentParameters parameters) {
    // Get base properties

    // customId < 10000 = block with no block.properties mapping -> mask 0
    // (default material). Unsigned subtraction would wrap, not clamp.
    uint material_mask = parameters.customId < 10000u
        ? 0u
        : parameters.customId - 10000u;

    vec3 tinting = parameters.tinting.rgb;
#if defined CHERRY_GROVE_PINK_GRASS && defined WORLD_OVERWORLD
    // Cherry grove pink on Voxy LoD terrain - matches the close-up terrain so distant
    // chunks don't POP green->pink as they load in. No dither at this range: a hard
    // pink/green switch at the biome midpoint (dither arg 0.5), riding Minecraft's own
    // per-block grass-colour blend for the border. Cheap: one colour test per fragment.
    tinting = cherry_grove_pink_grass(tinting, material_mask, 0.5);
#endif

    vec3 base_color = parameters.sampledColour.rgb * tinting;

    // from Cortex
    vec3 normal = vec3(
                      uint((parameters.face >> 1) == 2),
                      uint((parameters.face >> 1) == 0),
                      uint((parameters.face >> 1) == 1)
                  )
        * (float(int(parameters.face) & 1) * 2.0 - 1.0);

    // Exact axis vectors sit on the unit-vector encoding's fold seams; the
    // -Z face in particular can decode to garbage. Nudge it off the seam
    // (reference does the same in its own encoding).
    if (normal.z <= -0.9) {
        normal.xy = vec2(-1e-13);
    }

    // Encode gbuffer data

    gbuffer_data_0.x = pack_unorm_2x8(base_color.rg);
    gbuffer_data_0.y = pack_unorm_2x8(
        base_color.b,
        clamp01(float(material_mask) * rcp(255.0))
    );
    gbuffer_data_0.z = pack_unorm_2x8(encode_unit_vector(normal));
    gbuffer_data_0.w = pack_unorm_2x8(parameters.lightMap);
}
