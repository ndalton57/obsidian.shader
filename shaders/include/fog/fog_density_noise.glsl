#if !defined INCLUDE_FOG_FOG_DENSITY_NOISE
#define INCLUDE_FOG_FOG_DENSITY_NOISE

// 3D noise from the 2D noise texture (y/x channel pair, y-sliced, smoothstep
// interpolated - the fog variant; the overworld cloud field uses the
// unsmoothed version). Shared by the nether plume and End storm fog marches;
// the host program must define CLOUD_NOISETEX before including this.
float densityAtPosFog(in vec3 pos) {
    pos /= 18.0;
    pos.xz *= 0.5;

    vec3 p = floor(pos);
    vec3 f = fract(pos);

    f = (f * f) * (3.0 - 2.0 * f);
    vec2 uv = p.xz + f.xz + p.y * vec2(0.0, 193.0);
    vec2 coord = uv / 512.0;
    vec2 xy = texture(CLOUD_NOISETEX, coord).yx;

    return mix(xy.r, xy.g, f.y);
}

#endif // INCLUDE_FOG_FOG_DENSITY_NOISE
