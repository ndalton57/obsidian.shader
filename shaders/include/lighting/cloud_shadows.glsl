#if !defined INCLUDE_LIGHTING_CLOUD_SHADOWS
#define INCLUDE_LIGHTING_CLOUD_SHADOWS

#include "/include/utility/bicubic.glsl"

const ivec2 cloud_shadow_res = ivec2(512);

const float cloud_shadow_extent = 256.0 / (CLOUDS_SCALE / 10.0);

vec2 shadow_view_to_cloud_shadow_space(vec3 shadow_view_pos) {
    vec2 cloud_shadow_pos = shadow_view_pos.xy / cloud_shadow_extent;
    cloud_shadow_pos /= 1.0 + length(cloud_shadow_pos);
    cloud_shadow_pos = cloud_shadow_pos * 0.5 + 0.5;

    return cloud_shadow_pos;
}

vec2 project_cloud_shadow_map(vec3 scene_pos) {
    return shadow_view_to_cloud_shadow_space(
        transform(shadowModelView, scene_pos)
    );
}

vec3 unproject_cloud_shadow_map(vec2 cloud_shadow_pos) {
    cloud_shadow_pos = cloud_shadow_pos * 2.0 - 1.0;
    cloud_shadow_pos /= 1.0 - length(cloud_shadow_pos);

    vec3 shadow_view_pos = vec3(cloud_shadow_pos * cloud_shadow_extent, 1.0);

    return transform(shadowModelViewInverse, shadow_view_pos);
}

float get_cloud_shadows(sampler2D cloud_shadow_map, vec3 scene_pos) {
#ifndef CLOUD_SHADOWS
    return 1.0;
#else
    vec2 cloud_shadow_pos = project_cloud_shadow_map(scene_pos)
        * vec2(cloud_shadow_res) / vec2(textureSize(cloud_shadow_map, 0));

    if (clamp01(cloud_shadow_pos) != cloud_shadow_pos) {
        return 1.0;
    }

    // fade out cloud shadows when:
    //  - the fragment is above the lowest cloud layer
    //  - the sun is near the horizon
    float altitude_fraction = linear_step(
        CloudLayer0_height,
        CloudLayer0_height + 100.0,
        scene_pos.y + eyeAltitude
    );
    float cloud_shadow_fade = smoothstep(0.05, 0.15, light_dir.y)
        * clamp01(1.0 - altitude_fraction);

    float cloud_shadow = bicubic_filter(cloud_shadow_map, cloud_shadow_pos).x;
    cloud_shadow = cloud_shadow * cloud_shadow_fade + (1.0 - cloud_shadow_fade);

    return cloud_shadow * CLOUD_SHADOWS_INTENSITY
        + (1.0 - CLOUD_SHADOWS_INTENSITY);
#endif
}

#if defined PROGRAM_PREPARE && defined CLOUD_SHADOWS
#include "/include/sky/clouds.glsl"

vec2 render_cloud_shadow_map(vec2 uv) {
    // unproject_cloud_shadow_map returns a camera-relative scene position;
    // the cloud density functions want an absolute world position
    vec3 scene_pos = unproject_cloud_shadow_map(uv);

    return cloud_shadow_map_values(scene_pos + cameraPosition);
}
#endif
#endif // INCLUDE_LIGHTING_CLOUD_SHADOWS
