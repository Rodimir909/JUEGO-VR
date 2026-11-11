shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = UV;
	float edge_distance = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	float irregularity = 0.012 * sin(uv.x * 43.0 + sin(uv.y * 29.0));
	irregularity += 0.01 * sin(uv.y * 37.0 + uv.x * 17.0);
	float thickness = mix(0.018, 0.34, intensity);
	float edge = 1.0 - smoothstep(thickness * 0.28, thickness + irregularity, edge_distance);
	float blotches = max(0.0, sin(uv.x * 71.0 + sin(uv.y * 53.0)) * sin(uv.y * 67.0));
	blotches *= 1.0 - smoothstep(0.0, thickness * 1.4, edge_distance);
	float alpha = clamp((edge * 0.72 + blotches * 0.28) * intensity * 0.9, 0.0, 0.85);
	float depth = clamp(edge_distance / max(thickness, 0.001), 0.0, 1.0);
	vec3 blood = mix(vec3(0.48, 0.006, 0.025), vec3(0.10, 0.002, 0.008), depth);
	COLOR = vec4(blood, alpha);
}
