/*
--------------------------------------------------------------------------------

  Obsidian Shader

  program/gbuffers_all_solid:
  Handle terrain, entities, the hand, beacon beams and spider eyes

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

#if (defined GRASS_GEOMETRY || defined GRASS_VERTEX) && defined POM \
    && !defined PROGRAM_GBUFFERS_TERRAIN_SOLID
// Shader Grass build: POM stays off on the CUTOUT-terrain program (see the
// matching #undef in the vertex shader). The SOLID program keeps POM.
#undef POM
#endif

layout(
    location = 0
) out vec4 gbuffer_data_0; // albedo, block ID, flat normal, light levels
layout(
    location = 1
) out vec4 gbuffer_data_1; // detailed normal, specular map (optional)

/* RENDERTARGETS: 1 */

#ifdef NORMAL_MAPPING
/* RENDERTARGETS: 1,2 */
#endif

#ifdef SPECULAR_MAPPING
/* RENDERTARGETS: 1,2 */
#endif

#ifdef GRASS_GEOMETRY
// Shader Grass: receive the varyings from the geometry stage through the same
// (unnamed) interface block the geometry shader outputs. Member layout must
// match exactly. Only the SOLID terrain program defines GRASS_GEOMETRY (the
// cutout program has no geometry stage - its grass work happens in the
// vertex shader under GRASS_VERTEX, with the plain varyings below).
in GrassVertex {
    vec2 uv;
    vec3 scene_pos;
    vec4 tint;
    flat uint material_mask;
    flat mat3 tbn;
    vec2 light_levels;
    float vanilla_ao;
#ifdef POM
    vec2 atlas_tile_coord;
    vec3 tangent_pos;
    flat vec2 atlas_tile_offset;
    flat vec2 atlas_tile_scale;
#endif
};
#else
in vec2 uv;
in vec3 scene_pos;
in vec4 tint;

flat in uint material_mask;
flat in mat3 tbn;

#if defined POM
in vec2 atlas_tile_coord;
in vec3 tangent_pos;
flat in vec2 atlas_tile_offset;
flat in vec2 atlas_tile_scale;
#endif

#ifdef COLORWHEEL
vec2 light_levels;
float vanilla_ao;
#else
in vec2 light_levels;
#if defined PROGRAM_GBUFFERS_TERRAIN
in float vanilla_ao;
#endif
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES || defined PROGRAM_GBUFFERS_HAND
in vec2 uv_local;
#endif

#if defined PROGRAM_GBUFFERS_VOXELS
in vec3 block_normal;
#endif
#endif // GRASS_GEOMETRY

// ------------
//   Uniforms
// ------------

uniform sampler2D noisetex;

uniform sampler2D gtexture;

#if defined NORMAL_MAPPING || defined POM
uniform sampler2D normals;
#endif

#if defined SPECULAR_MAPPING
uniform sampler2D specular;
#endif

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform vec3 cameraPosition;
#if defined CHERRY_GROVE_PINK_GRASS && defined PROGRAM_GBUFFERS_TERRAIN
// Iris split camera, for a frame-stable cherry-grove dither texel (see the recolor below).
uniform ivec3 cameraPositionInt;
uniform vec3 cameraPositionFract;
#endif

uniform float near;
uniform float far;

uniform int frameCounter;
uniform float frameTimeCounter;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec2 taa_offset;

uniform vec3 light_dir;

uniform float alphaTestRef = 0.1;

#if defined PROGRAM_GBUFFERS_ENTITIES
uniform int entityId;
uniform vec4 entityColor;
#endif

#if defined PROGRAM_GBUFFERS_PARTICLES
#define NO_NORMAL
#endif

#if defined PROGRAM_GBUFFERS_TERRAIN && defined POM
#include "/include/surface/parallax.glsl"
#endif

#ifdef DIRECTIONAL_LIGHTMAPS
#include "/include/lighting/directional_lightmaps.glsl"
#endif

#include "/include/misc/material_fix.glsl"
#include "/include/misc/material_masks.glsl"

#if defined CHERRY_GROVE_PINK_GRASS && defined PROGRAM_GBUFFERS_TERRAIN
#include "/include/misc/cherry_grove.glsl"
#endif
#include "/include/utility/dithering.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/space_conversion.glsl"

#if defined PROGRAM_GBUFFERS_VOXELS
#include "/photonics/photonics.glsl"
#endif

#if defined PROGRAM_GBUFFERS_TERRAIN && defined POM
#define read_tex(x) textureGrad(x, parallax_uv, uv_gradient[0], uv_gradient[1])
#else
#define read_tex(x) texture(x, uv, lod_bias)
#endif

#if TEXTURE_FORMAT == TEXTURE_FORMAT_LAB
void decode_normal_map(vec3 normal_map, out vec3 normal, out float ao) {
    normal.xy = normal_map.xy * 2.0 - 1.0;
    normal.z = sqrt(clamp01(1.0 - dot(normal.xy, normal.xy)));
    ao = normal_map.z;
}
#elif TEXTURE_FORMAT == TEXTURE_FORMAT_OLD
void decode_normal_map(vec3 normal_map, out vec3 normal, out float ao) {
    normal = normal_map * 2.0 - 1.0;
    ao = length(normal);
    normal *= rcp(ao);
}
#endif

#if defined PROGRAM_GBUFFERS_BLOCK
vec3 draw_end_portal() {
    const int layer_count = 8; // Number of layers
    const float depth_scale = 0.33; // Apparent distance between layers
    const float depth_fade = 0.5; // How quickly the layers fade to black
    const float threshold = 0.99; // Threshold for the "stars". Lower values
                                  // mean more stars appear
    const float twinkle_speed = 0.4; // How fast the stars appear to twinkle
    const float twinkle_amount = 0.04; // How many twinkling stars appear
    const vec3 color0 = pow(vec3(0.80, 0.90, 0.99), vec3(2.2));
    const vec3 color1 = pow(vec3(0.75, 0.40, 0.93), vec3(2.2));
    const vec3 color2 = pow(vec3(0.20, 0.70, 0.90), vec3(2.2));

    vec3 screen_pos = vec3(
        gl_FragCoord.xy * view_pixel_size * rcp(taau_render_scale),
        gl_FragCoord.z
    );
    vec3 view_pos = screen_to_view_space(screen_pos, true);
    vec3 scene_pos = view_to_scene_space(view_pos);

    vec3 world_pos = scene_pos + cameraPosition;
    vec3 world_dir = normalize(scene_pos - gbufferModelViewInverse[3].xyz);

    // Get tangent-space position/direction without tangent/bitangent

    vec2 tangent_pos, tangent_dir;
    if (abs(tbn[2].x) > 0.5) {
        tangent_pos = world_pos.yz;
        tangent_dir = world_dir.yz / abs(world_dir.x + eps);
    } else if (abs(tbn[2].y) > 0.5) {
        tangent_pos = world_pos.xz;
        tangent_dir = world_dir.xz / abs(world_dir.y + eps);
    } else {
        tangent_pos = world_pos.xy;
        tangent_dir = world_dir.xy / abs(world_dir.z + eps);
    }

    vec3 result = vec3(0.0);

    for (int i = 0; i < layer_count; ++i) {
        // Random layer offset
        vec2 layer_offset = r2(i) * 512.0;

        // Make layers drift over time
        float angle = i * golden_angle;
        vec2 drift
            = 0.033 * vec2(cos(angle), sin(angle)) * frameTimeCounter * r1(i);

        // Snap tangent_pos to a grid and calculate a seed for the RNG
        ivec2 grid_pos = ivec2((tangent_pos + drift) * 32.0 + layer_offset);
        uint seed = uint(80000 * grid_pos.y + grid_pos.x);

        // 4 random numbers for this grid cell
        vec4 random = rand_next_vec4(seed);

        // Twinkling animation
        float twinkle_offset = tau * random.w;
        random.x *= 1.0
            - twinkle_amount
                * cos(frameTimeCounter * twinkle_speed + twinkle_offset);

        // Stomp all values below threshold to zero
        float intensity = pow8(linear_step(threshold, 1.0, random.x));

        // Blend between the 3 colors
        vec3 color = mix(color0, color1, random.y);
        color = mix(color, color2, random.z);

        // Fade away with depth
        float fade = exp2(-depth_fade * float(i));

        result += color * intensity * exp2(-3.0 * (1.0 - fade) * (1.0 - color))
            * fade;

        // Step along the view ray
        tangent_pos
            += tangent_dir * depth_scale * gbufferProjection[1][1] * rcp(1.37);

        if (random.x > threshold) {
            break;
        }
    }

    result *= 0.8;
    result = sqrt(result);
    result *= sqrt(result);

    return result;
}
#endif

const float lod_bias = log2(taau_render_scale);

void main() {
#if defined TAA && defined TAAU
    vec2 coord = gl_FragCoord.xy * view_pixel_size * rcp(taau_render_scale);
    if (clamp01(coord) != coord) {
        discard;
        return;
    }
#endif

    bool parallax_shadow = false;
    float dither = interleaved_gradient_noise(gl_FragCoord.xy, frameCounter);

#ifndef PROGRAM_GBUFFERS_VOXELS
#if defined PROGRAM_GBUFFERS_TERRAIN && defined POM
    float view_distance = length(tangent_pos);

    bool has_pom
        = view_distance < POM_DISTANCE; // Only calculate POM for close terrain
    has_pom = has_pom
        && material_mask
            != MATERIAL_LAVA; // Do not calculate POM for water or lava
    // Shader Grass: blades grown by the geometry shader are tagged as small
    // plants and carry no parallax data, so skip POM for them (they fall into
    // the `parallax_uv = uv` branch below and texture normally).
    has_pom = has_pom && material_mask != MATERIAL_SMALL_PLANTS
        && !is_flower_mask(material_mask)
        && material_mask != uint(MATERIAL_AMETHYST_BLADE)
        && material_mask != uint(MATERIAL_FIREFLY_BLADE);

    vec3 tangent_dir = -normalize(tangent_pos);
    mat2 uv_gradient = mat2(dFdx(uv), dFdy(uv));

    vec2 parallax_uv;

    if (has_pom) {
        float pom_depth;
        vec3 shadow_trace_pos;

        parallax_uv = get_parallax_uv(
            tangent_dir,
            uv_gradient,
            view_distance,
            dither,
            shadow_trace_pos,
            pom_depth
        );
#ifdef POM_SHADOW
        if (dot(tbn[2], light_dir) >= eps) {
            parallax_shadow = get_parallax_shadow(
                shadow_trace_pos,
                uv_gradient,
                view_distance,
                dither
            );
        } else {
            parallax_shadow = false;
        }
#endif
    } else {
        parallax_uv = uv;
        parallax_shadow = false;
    }
#endif

    //--//

    vec4 base_color;
#if defined COLORWHEEL
    base_color = read_tex(gtexture);
    vec4 overlayColor;

    clrwl_computeFragment(
        base_color,
        base_color,
        light_levels,
        vanilla_ao,
        overlayColor
    );
    light_levels = clamp((light_levels - 1.0 / 32.0) * 32.0 / 30.0, 0.0, 1.0);
#elif defined CHERRY_GROVE_PINK_GRASS && defined PROGRAM_GBUFFERS_TERRAIN
    // Cherry grove: dither the grass block top, side fringe and short grass fully pink or
    // fully their biome green, per TEXEL (1/16-block world cells, 3D so it works on every
    // face). The solid shader-grass blades are dithered per-blade in the geometry shader,
    // so skip them here (material 2 in the solid program is a blade; in the cutout program
    // it is short grass, dither it).
    vec4 cherry_tint = tint;
    bool cherry_is_blade = false;
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    // Every GS-grown blade mask counts, not just the plain one: the glow
    // blade masks otherwise fall into the per-texel machinery below, whose
    // derivative extrapolation bands badly on thin blade geometry
    cherry_is_blade = material_mask == MATERIAL_SMALL_PLANTS
        || material_mask == uint(MATERIAL_AMETHYST_BLADE)
        || material_mask == uint(MATERIAL_FIREFLY_BLADE);
#endif
    if (!cherry_is_blade) {
        // Stable, texture-ALIGNED per-texel key. Load-bearing pieces: (1) the Iris SPLIT camera
        // (exact integer world texel cameraPositionInt*16 + precise sub-texel offset), so the
        // collapsed world's ~1-ULP wobble can't flip floor() far from spawn; (2) the +0.5 guard -
        // but ONLY on the face-NORMAL axis. A face sits on an integer world coord along its normal,
        // landing EXACTLY on a *16 texel boundary where floor() flips under the tiniest reconstruction
        // wobble (top face under VERTICAL motion, a side under HORIZONTAL) - +0.5 there centres it
        // mid-cell. Adding +0.5 on the IN-PLANE axes instead shifts the dither grid half a texel off
        // the TEXTURE grid, so each texture texel straddles two dither cells and the recolor splits it
        // in half. Guarding the normal axis ONLY keeps the in-plane cells aligned to texels.
        vec3 cherry_offset = 0.5 * abs(round(tbn[2]));
        vec3 cherry_wpos = (scene_pos + cameraPositionFract) * 16.0 + cherry_offset;
        ivec3 cherry_texel = cameraPositionInt * 16 + ivec3(floor(cherry_wpos));

        // WHOLE-TEXEL recolor: evaluate the pink-probability at the TEXEL CENTRE, not per-pixel.
        // The dither roll is already constant per texel, but the probability comes from the biome
        // tint, which varies per-pixel - so without this the pink/green boundary follows the smooth
        // biome gradient and cuts a diagonal across the texel (the "triangles"). The tint is affine
        // on the planar face, so extrapolate it from this pixel to the texel centre using screen
        // derivatives (taken in uniform control flow, before the branch), which makes the probability
        // - and thus the whole texel's choice - constant. The offset is sub-texel, so the nudge is
        // bounded by the real biome gradient (no false recolor of other grass), and the det test is
        // scale-invariant so it works at any distance (skips only grazing/degenerate frames).
        vec3 to_center = (vec3(0.5) - fract(cherry_wpos)) * (1.0 / 16.0);
        vec3 dpdx = dFdx(scene_pos), dpdy = dFdy(scene_pos);
        vec3 dtdx = dFdx(cherry_tint.rgb), dtdy = dFdy(cherry_tint.rgb);
        float a11 = dot(dpdx, dpdx), a12 = dot(dpdx, dpdy), a22 = dot(dpdy, dpdy);
        float det = a11 * a22 - a12 * a12;
        vec3 tint_at_texel = cherry_tint.rgb;
        if (det > 1e-6 * a11 * a22) {
            float b1 = dot(to_center, dpdx), b2 = dot(to_center, dpdy);
            float u = (b1 * a22 - b2 * a12) / det;
            float v = (a11 * b2 - a12 * b1) / det;
            tint_at_texel += u * dtdx + v * dtdy;
        }
        cherry_tint.rgb = cherry_grove_pink_grass(
            tint_at_texel, material_mask, cherry_grove_dither(vec3(cherry_texel))
        );
    }
    base_color = read_tex(gtexture) * cherry_tint;
#else
    base_color = read_tex(gtexture) * tint;
#endif

#ifdef NORMAL_MAPPING
    vec3 normal_map = read_tex(normals).xyz;
#endif
#ifdef SPECULAR_MAPPING
    vec4 specular_map = read_tex(specular);
#endif

#if defined PROGRAM_GBUFFERS_TERRAIN_SOLID && defined SHADER_GRASS \
    && defined GRASS_FLOWERS
    if (material_mask >= uint(MATERIAL_FLOWER_FIRST)
        && material_mask <= uint(MATERIAL_FLOWER_LAST)) {
        // Generated flower-head quad (grown by the terrain geometry shader
        // above a stalk). uv carries the quad's local coords ([-1,1]^2,
        // pre-rotated per head in the GS), tint.a the flower block's
        // palette-cell code and tint.rgb the family fallback colour. The
        // disc is drawn PIXEL-ART style: coords quantized to a chunky texel
        // grid, and each texel coloured from the flower's REAL sprite
        // palette - four texels the shadow pass captured from the flower's
        // own texture (see update_flower_palette) - so a head mirrors the
        // actual bloom's colour range. The head carries no texture maps.
        // Texel-centre coords on a ~10-texel grid across the head
        const float head_px = 5.0;
        vec2 head_g = floor(uv * head_px);
        vec2 p = (head_g + 0.5) * (1.0 / head_px);

        float r = length(p);
        float theta = atan(p.y, p.x);

        // Per-family petal SHAPE only - every colour, centre included, comes
        // from the flower's own palette, so no head ever shows a hue its
        // sprite doesn't have
        // Even petal counts only: an odd count can never sit symmetrically
        // on the square texel grid. petal_edge sharpens the valleys between
        // petals (higher = more separated petals).
        float petals;
        float centre_r;
        float petal_edge = 0.7;
        if (material_mask == uint(MATERIAL_FLOWER_RED)) {
            petals = 4.0; // poppy: broad petals, deep heart
            centre_r = 0.30;
        } else if (material_mask == uint(MATERIAL_FLOWER_YELLOW)) {
            petals = 12.0; // dandelion: fluffy, deeper core
            centre_r = 0.22;
        } else if (material_mask == uint(MATERIAL_FLOWER_BLUE)) {
            petals = 8.0; // cornflower: fringe of eight, crisper petal
            centre_r = 0.22; // separation than the daisy's
            petal_edge = 0.9;
        } else if (material_mask == uint(MATERIAL_FLOWER_PURPLE)) {
            petals = 12.0; // allium pompom: dense scalloped ball, no heart
            centre_r = 0.0;
        } else {
            petals = 8.0; // daisy
            centre_r = 0.26;
        }

        float scallop = pow(abs(cos(theta * petals * 0.5)), petal_edge);
        float rim = 0.60 + 0.40 * scallop;
        if (r > rim) {
            discard;
            return;
        }

        // Two petal tones from the geometry shader: tint.rgb = petal tone,
        // tint.a = ring tone packed 5:5:5. The packed value is small, so it
        // interpolates bit-exactly across the quad - a large index here
        // picked up per-fragment rounding and flickered texels on any
        // camera move. Structure stays: bright petals, darker outer ring,
        // family centre; each texel then gets only a SUBTLE wobble.
        int f_pk = int(tint.a + 0.5);
        vec3 f_dark = f_pk > 0
            ? vec3(float((f_pk >> 10) & 31), float((f_pk >> 5) & 31),
                   float(f_pk & 31))
                * (1.0 / 31.0)
            : tint.rgb * 0.72;

        uint fh = uint(int(head_g.x) + 57) * 0x8da6b343u
            ^ uint(int(head_g.y) + 23) * 0xd8163841u
            ^ uint(f_pk) * 0x9E3779B1u;
        fh = (fh ^ (fh >> 13)) * 0x9E3779B1u;
        fh ^= fh >> 16;

        vec3 petal_col = (r > rim * 0.66) ? f_dark : tint.rgb;
        if (r < centre_r) {
            petal_col = f_dark * 0.75; // deeper core in the bloom's own hue
        }
        petal_col = mix(petal_col, (r > rim * 0.66) ? tint.rgb : f_dark,
                        0.10 * float(fh & 3u) * (1.0 / 3.0));
        petal_col *= 0.94 + 0.12 * float((fh >> 8) & 255u) * (1.0 / 255.0);
        // The gbuffer packs albedo into 8-bit fields with NO clamp - a
        // component pushed past 1.0 by the stacked jitters overflows into
        // the neighbouring byte and wraps the hue entirely (white -> green,
        // blue -> yellow, red -> dark blue), one corrupted texel at a time
        petal_col = clamp01(petal_col);
        base_color = vec4(petal_col, 1.0);
#ifdef NORMAL_MAPPING
        normal_map = vec3(0.5, 0.5, 1.0); // flat
#endif
#ifdef SPECULAR_MAPPING
        specular_map = vec4(0.0);
#endif
    }
#endif
#else
    vec3 screen_pos = vec3(
        gl_FragCoord.xy * view_pixel_size * rcp(taau_render_scale),
        gl_FragCoord.z
    );

    vec3 view_pos = screen_to_view_space(screen_pos, true);
    vec3 scene_pos = view_to_scene_space(view_pos);

    vec3 world_pos = scene_pos + cameraPosition;
    vec3 world_dir = normalize(scene_pos - gbufferModelViewInverse[3].xyz);

    RayJob ray = RayJob(
        world_pos - world_offset - 0.001f * block_normal, // Ray origin
        world_dir, // Ray direction
        vec3(0),
        vec3(0),
        vec3(0),
        false
    );

    ray_constraint = ivec3(ray.origin);
    trace_ray(ray);

    if (!ray.result_hit) {
        discard;
    }
    if (ray.result_normal == vec3(0.0)) {
        ray.result_normal = block_normal;
    }

    scene_pos = ray.result_position + world_offset - cameraPosition;
    view_pos = scene_to_view_space(scene_pos);
    screen_pos = view_to_screen_space(gbufferProjection, view_pos, true);

    gl_FragDepth = screen_pos.z;

    vec4 base_color = vec4(ray.result_color, 1.0f);
    vec3 ph_normal = ray.result_normal;

#if defined SPECULAR_MAPPING
    vec4 specular_map = vec4(0.0f);
#endif
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES
    if (material_mask == MATERIAL_LIGHTNING_BOLT) {
        base_color = vec4(1.0);
    }
    if (base_color.a < alphaTestRef && material_mask != MATERIAL_BOAT) {
        discard;
        return;
    } // Save transparent quad in boats, which masks out water
#elif !defined PROGRAM_GBUFFERS_TERRAIN_SOLID
    if (base_color.a < alphaTestRef) {
        discard;
        return;
    }
#endif

#if ( \
    defined PROGRAM_GBUFFERS_BLOCK || defined PROGRAM_GBUFFERS_ENTITIES \
    || defined PROGRAM_GBUFFERS_HAND \
) && !(defined USE_SEPARATE_ENTITY_DRAWS && defined IS_IRIS)
#ifdef DITHERED_TRANSLUCENCY_FALLBACK
    // Dithered transparency for translucent objects rendered as solid
    float dither_pattern = r1(
        frameCounter,
        texelFetch(noisetex, ivec2(gl_FragCoord.xy) & 511, 0).z
    );
    if (base_color.a < dither_pattern) {
        discard;
        return;
    }
#endif
#endif

#ifdef WHITE_WORLD
    base_color.rgb = vec3(1.0);
#endif

#if defined PROGRAM_GBUFFERS_TERRAIN && defined VANILLA_AO
#if SHADER_AO != SHADER_AO_NONE
    const float vanilla_ao_strength = 0.9;
    const float vanilla_ao_lift = 0.5;
#else
    const float vanilla_ao_strength = 1.0;
    const float vanilla_ao_lift = 0.0;
#endif

    base_color.rgb *= lift(vanilla_ao, vanilla_ao_lift) * vanilla_ao_strength
        + (1.0 - vanilla_ao_strength);
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES
    base_color.rgb = mix(base_color.rgb, entityColor.rgb, entityColor.a);
#endif

#if defined COLORWHEEL
    base_color.rgb = mix(base_color.rgb, overlayColor.rgb, overlayColor.a);
#endif

#if defined PROGRAM_GBUFFERS_BLOCK
    // parallax end portal
    if (material_mask == MATERIAL_END_PORTAL) {
        base_color.rgb = draw_end_portal();
    }
#endif

#if defined PROGRAM_GBUFFERS_BEACONBEAM
    // Discard the translucent edge part of the beam
    if (base_color.a < 0.5) {
        discard;
    }
#endif

    vec2 adjusted_light_levels = light_levels;

#if defined NORMAL_MAPPING && !defined PROGRAM_GBUFFERS_VOXELS
    vec3 normal;
    float material_ao;
    decode_normal_map(normal_map, normal, material_ao);

    normal = tbn * normal;

    adjusted_light_levels *= mix(0.7, 1.0, material_ao);

#ifdef DIRECTIONAL_LIGHTMAPS
    adjusted_light_levels *= get_directional_lightmaps(scene_pos, normal);
#endif
#endif

#if defined PROGRAM_GBUFFERS_VOXELS
#define flat_normal ph_normal
#define detailed_normal ph_normal
#elif defined NO_NORMAL
    // No normal vector => make one from screen-space partial derivatives
    vec3 particle_normal = normalize(cross(dFdx(scene_pos), dFdy(scene_pos)));
#define flat_normal particle_normal
#define detailed_normal particle_normal
#else
#define flat_normal tbn[2]
#define detailed_normal normal
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES || defined PROGRAM_GBUFFERS_HAND
    uint new_material_mask = fix_material_mask();
#define material_mask new_material_mask
#endif

    gbuffer_data_0.x = pack_unorm_2x8(base_color.rg);
    gbuffer_data_0.y = pack_unorm_2x8(
        base_color.b,
        clamp01(float(material_mask) * rcp(255.0))
    );
    gbuffer_data_0.z = pack_unorm_2x8(encode_unit_vector(flat_normal));
    gbuffer_data_0.w
        = pack_unorm_2x8(dither_8bit(adjusted_light_levels, dither));

#ifdef NORMAL_MAPPING
    gbuffer_data_1.xy = encode_unit_vector(detailed_normal);
#endif

#ifdef SPECULAR_MAPPING
#if defined POM && defined POM_SHADOW
    // Pack parallax shadow in alpha component of specular map
    // Specular map alpha >= 0.5 => parallax shadow
    specular_map.a *= step(specular_map.a, 0.999);
    specular_map.a
        = clamp01(specular_map.a * 0.5 + 0.5 * float(parallax_shadow));
#endif

    gbuffer_data_1.z = pack_unorm_2x8(specular_map.xy);
    gbuffer_data_1.w = pack_unorm_2x8(specular_map.zw);
#else
#if defined POM && defined POM_SHADOW
    gbuffer_data_1.z = float(parallax_shadow);
#endif
#endif

#if defined PROGRAM_GBUFFERS_PARTICLES
    // Kill the little rain splash particles
    if (base_color.r < 0.29 && base_color.g < 0.45 && base_color.b > 0.75) {
        discard;
    }
#endif
}
