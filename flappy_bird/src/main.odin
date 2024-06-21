package flappy

import "vendor:raylib"

RENDER_WIDTH  :: 800;
RENDER_HEIGHT :: 600;

Vector2 :: [2]f32;

WORLD_WIDTH  :: 800;
WORLD_HEIGHT :: 600;

WORLD_CENTER_X :: 0.5 * WORLD_WIDTH
WORLD_CENTER_Y :: 0.5 * WORLD_HEIGHT

main :: proc() {
	raylib.InitWindow(RENDER_WIDTH, RENDER_HEIGHT, "Flappy!");
	if raylib.IsWindowReady() {
		raylib.SetExitKey(raylib.KeyboardKey.KEY_NULL);
		raylib.SetTargetFPS(60);
		
		camera : raylib.Camera3D;
		camera.position   = { 0, 0, -10 }; // Position of the camera in 3D world space
		camera.target     = { 0, 0, 0 }; // Position of the camera's target (what it's looking at)
		camera.up         = { 0, 1, 0 }; // The vector used to determine th ecamera's left and right rotations
		camera.fovy       = 18; // How many worldspace units are mapped to screen Y
		camera.projection = raylib.CameraProjection.ORTHOGRAPHIC;
		
		p_pos: Vector2;
		p_vel: Vector2;
		G :: 9.81;
		p_acc := Vector2{ 0, G };
		
		multiplier :: 4;
		
		for !raylib.WindowShouldClose() {
			
			dt := raylib.GetFrameTime();
			
			p_pos = p_pos + p_vel*dt + p_acc*multiplier*(dt*dt*0.5);
			p_vel = p_vel + p_acc*multiplier*dt*0.5;
			
			raylib.BeginDrawing();
			raylib.ClearBackground(raylib.RAYWHITE);
			
			raylib.BeginMode3D(camera);
			{
				p_render_pos := Vector2 { p_pos.x, -p_pos.y };
				raylib.DrawCircleV(p_render_pos, 1, raylib.RED);
			}
			raylib.EndMode3D();
			
			raylib.EndDrawing();
		}
	}
}
