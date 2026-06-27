#if !defined INCLUDE_MISC_DEBUG_WEATHER
#define INCLUDE_MISC_DEBUG_WEATHER

uniform int worldTime;
uniform int worldDay;
uniform float sunAngle;

uniform float rainStrength;
uniform float wetness;

uniform vec3 light_dir;
uniform vec3 sun_dir;
uniform vec3 moon_dir;

uniform float world_age;

uniform float time_sunrise;
uniform float time_noon;
uniform float time_sunset;
uniform float time_midnight;

uniform float biome_cave;
uniform float biome_temperate;
uniform float biome_arid;
uniform float biome_snowy;
uniform float biome_taiga;
uniform float biome_jungle;
uniform float biome_swamp;
uniform float biome_may_rain;
uniform float biome_may_snow;
uniform float biome_temperature;
uniform float biome_humidity;

uniform float desert_sandstorm;

#include "/include/weather/core.glsl"

void debug_weather(inout vec3 color) {
    const int number_col = 30;

    Weather weather = get_weather();

    // Cloud layer values (static settings blended toward storm values
    // by rainStrength, mirroring include/sky/clouds/field.glsl)
    float l0_coverage = mix(CloudLayer0_coverage, Rain_coverage, rainStrength);
    float l1_coverage = mix(CloudLayer1_coverage, 0.0, rainStrength);
    float l2_coverage = mix(CloudLayer2_coverage, 1.5, rainStrength);
    float l0_density = mix(CloudLayer0_density, 1.0, rainStrength);
    float l1_density = mix(CloudLayer1_density, 0.0, rainStrength);
    float l2_density = mix(CloudLayer2_density, 0.05, rainStrength);

    begin_text(ivec2(gl_FragCoord.xy) / debug_text_scale, debug_text_position);
    text.bg_col = vec4(0.0);
    print((_W, _E, _A, _T, _H, _E, _R));
    print_line();
    print((_T, _e, _m, _p, _e, _r, _a, _t, _u, _r, _e));
    text.char_pos.x = number_col;
    print_float(weather.temperature);
    print_line();
    print((_H, _u, _m, _i, _d, _i, _d, _i, _t, _y));
    text.char_pos.x = number_col;
    print_float(weather.humidity);
    print_line();
    print(
        (_B, _i, _o, _m, _e, _space, _t, _e, _m, _p, _e, _r, _a, _t, _u, _r, _e)
    );
    text.char_pos.x = number_col;
    print_float(biome_temperature);
    print_line();
    print((_B, _i, _o, _m, _e, _space, _r, _a, _i, _n, _f, _a, _l, _l));
    text.char_pos.x = number_col;
    print_float(biome_humidity);
    print_line();
    print((_W, _i, _n, _d));
    text.char_pos.x = number_col;
    print_float(weather.wind);
    print_line();
    print((_R, _a, _i, _n, _space, _s, _t, _r, _e, _n, _g, _t, _h));
    text.char_pos.x = number_col;
    print_float(rainStrength);
    print_line();
    print_line();
    print((_C, _L, _O, _U, _D, _S));
    print_line();
    print(
        (_L, _a, _y, _e, _r, _space, _0, _space, _c, _o, _v, _e, _r, _a, _g, _e)
    );
    text.char_pos.x = number_col;
    print_float(l0_coverage);
    print_line();
    print(
        (_L, _a, _y, _e, _r, _space, _0, _space, _d, _e, _n, _s, _i, _t, _y)
    );
    text.char_pos.x = number_col;
    print_float(l0_density);
    print_line();
    print(
        (_L, _a, _y, _e, _r, _space, _1, _space, _c, _o, _v, _e, _r, _a, _g, _e)
    );
    text.char_pos.x = number_col;
    print_float(l1_coverage);
    print_line();
    print(
        (_L, _a, _y, _e, _r, _space, _1, _space, _d, _e, _n, _s, _i, _t, _y)
    );
    text.char_pos.x = number_col;
    print_float(l1_density);
    print_line();
    print(
        (_L, _a, _y, _e, _r, _space, _2, _space, _c, _o, _v, _e, _r, _a, _g, _e)
    );
    text.char_pos.x = number_col;
    print_float(l2_coverage);
    print_line();
    print(
        (_L, _a, _y, _e, _r, _space, _2, _space, _d, _e, _n, _s, _i, _t, _y)
    );
    text.char_pos.x = number_col;
    print_float(l2_density);
    print_line();
    end_text(color);
}

#endif // INCLUDE_MISC_DEBUG_WEATHER
