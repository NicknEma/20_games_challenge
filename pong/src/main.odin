package pong

/* @Todo:
** - Audio
**  - Better understand volume
**
** - Robustness
**  - Use arenas on startup
**
** - Polish
**  - Make a better icon
**
** - Features
**  - Make PvE mode with artificial opponent
*/

/* @Note: References used to make this game:
** - For using win32 resources:
**   http://www.winprog.org/tutorial/resources.html
*/

import "base:runtime"
import "base:intrinsics"

import "core:fmt"; _ :: fmt
import "core:time"
import "core:math"
import "core:math/rand"
import "core:strings"
import "core:reflect"

import "vendor:raylib"

import "core:sys/windows"

RENDER_WIDTH  :: 800;
RENDER_HEIGHT :: 600;

Vector2 :: [2]f32

Box2 :: struct {
	position: Vector2,
	half_size: Vector2,
}

Solid :: struct {
	box: Box2,
	color: raylib.Color,
	
	up_key,
	down_key: raylib.KeyboardKey,
	
	hit_action: Hit_Action_Kind,
}

Hit_Action_Kind :: enum {
	None,
	Player0_Scores,
	Player1_Scores,
}

main :: proc() {
	raylib.InitWindow(RENDER_WIDTH, RENDER_HEIGHT, "Pong!");
	if raylib.IsWindowReady() {
		
		when ODIN_OS == .Windows {
			//- Set the window icon.
			// Raylib offers a platform-agnostic way of setting the icon, but that would require keeping a separate file for the icon.
			// By using the windoes API we can load the icon from the executable's resources embedded within it.
			
			IDI_PONG_ICON :: 101; // @Note: Must be kept always in sync with resources.h
			
			ICON_SMALL :: 0; // Defined in WinUser.h, missing from windows.odin
			ICON_BIG   :: 1;
			
			module_handle := windows.GetModuleHandleW(nil);
			window_handle := cast(windows.HWND) raylib.GetWindowHandle();
			icon_handle   := windows.LoadIconW(cast(windows.HANDLE) module_handle, windows.MAKEINTRESOURCEW(IDI_PONG_ICON));
			
			windows.SendMessageW(window_handle, windows.WM_SETICON, ICON_SMALL, cast(windows.LPARAM) uintptr(icon_handle));
			windows.SendMessageW(window_handle, windows.WM_SETICON, ICON_BIG,   cast(windows.LPARAM) uintptr(icon_handle));
		}
		
		raylib.SetExitKey(raylib.KeyboardKey.KEY_NULL);
		raylib.SetTargetFPS(60);
		raylib.InitAudioDevice();
		use_audio := raylib.IsAudioDeviceReady();
		
		//- Init camera.
		camera : raylib.Camera2D;
		camera.target = { 0, 0 };
		camera.offset = 0.5 * { RENDER_WIDTH, RENDER_HEIGHT };
		camera.rotation = 0.0;
		camera.zoom   = 1.0;
		
		//- Make graphical assets.
		raylib_default_font := raylib.GetFontDefault();
		
		//- Make audio assets.
		bump_sound : raylib.Sound;
		play_sound : raylib.Sound;
		kill_sound : raylib.Sound;
		{
			// If a wave is invalid, IsWaveReady returns false; when a wave is invalid, LoadSoundFromWave returns a zeroed out struct, which means it doesn't have to be freed.
			// It's likely that LoadSoundFromWave calls IsWaveReady, so there's no point in calling it ourselves except maybe inside an assert.
			// Since the Sound struct doesn't have to be freed, we never call UnloadSound (we never free valid sounds as they last for the whole duration of the game).
			// We would only need to free the wave, in case could happen that it was invalid. BUT the wave needs to be valid, otherwise it's a programmer bug and that should never happen.
			
			samples_per_second := 48000;
			bits_per_sample    := 16;
			channel_count      := 2;
			
			//- Make the "bump" sound effect.
			
			env := Envelope {
				attack_seconds    = 0.05,
				decay_seconds     = 0.01,
				release_seconds   = 0.10,
				
				sustain_amplitude = 0.50,
				start_amplitude   = 1.00,
			}
			
			sustain_seconds := 0.1;
			seconds         := env.attack_seconds + env.decay_seconds + sustain_seconds;
			
			if wave, success := make_wave(seconds, samples_per_second, bits_per_sample, channel_count, .Triangle, env); success {
				bump_sound = raylib.LoadSoundFromWave(wave);
				assert(raylib.IsSoundReady(bump_sound));
			} else {
				assert(wave.data == nil); // The only allowed error is an allocation error. Anything else is due to bad argument values, which are a programmer bug.
			}
			
			//- Make the "kill" sound effect.
			
			env.start_amplitude   = 0.6;
			env.sustain_amplitude = 1.0;
			{
				wave1, success1 := make_wave(seconds, samples_per_second, bits_per_sample, channel_count, .Triangle, env, 0.9);
				wave2, success2 := make_wave(seconds, samples_per_second, bits_per_sample, channel_count, .Triangle, env, 0.7);
				wave3, success3 := make_wave(seconds, samples_per_second, bits_per_sample, channel_count, .Triangle, env, 0.5);
				
				// @Todo: free() the temporary waves.
				
				wave : raylib.Wave;
				success := success1 && success2 && success3;
				if success {
					wave, success = concatenate_waves({ wave1, wave2, wave3 });
				}
				
				if success {
					kill_sound = raylib.LoadSoundFromWave(wave);
					assert(raylib.IsSoundReady(kill_sound));
				} else {
					assert(wave.data == nil); // The only allowed error is an allocation error. Anything else is due to bad argument values, which are a programmer bug.
				}
			}
			
			//- Make the "play" sound effect.
			
			sustain_seconds       = 0.15;
			seconds               = env.attack_seconds + env.decay_seconds + sustain_seconds;
			env.start_amplitude   = 0.8;
			env.sustain_amplitude = 0.4;
			
			if wave, success := make_wave(seconds, samples_per_second, bits_per_sample, channel_count, .Triangle, env, 3.0); success {
				play_sound = raylib.LoadSoundFromWave(wave);
				assert(raylib.IsSoundReady(play_sound));
			} else {
				assert(wave.data == nil); // The only allowed error is an allocation error. Anything else is due to bad argument values, which are a programmer bug.
			}
		}
		
		state := &global_state;
		
		{
			//- Init game state.
			
			_, _, seed := time.clock(time.now());
			state.ball_start_direction_entropy = rand.create(u64(seed));
			state.ball_box.half_size = 0.5 * BALL_SIZE;
			state.ball_speed = BALL_START_SPEED;
			
			state.all_solids = {
				{ {{ -RENDER_WIDTH / 2, 0 }, { SCREEN_BORDER_PADDING, RENDER_HEIGHT }}, raylib.BLANK, raylib.KeyboardKey.KEY_NULL, raylib.KeyboardKey.KEY_NULL, .Player1_Scores }, // left edge
				{ {{ +RENDER_WIDTH / 2, 0 }, { SCREEN_BORDER_PADDING, RENDER_HEIGHT }}, raylib.BLANK, raylib.KeyboardKey.KEY_NULL, raylib.KeyboardKey.KEY_NULL, .Player0_Scores }, // right edge
				{ {{ 0, +RENDER_HEIGHT / 2 }, { RENDER_WIDTH, SCREEN_BORDER_PADDING }}, raylib.BLANK, raylib.KeyboardKey.KEY_NULL, raylib.KeyboardKey.KEY_NULL, .None }, // top edge
				{ {{ 0, -RENDER_HEIGHT / 2 }, { RENDER_WIDTH, SCREEN_BORDER_PADDING }}, raylib.BLANK, raylib.KeyboardKey.KEY_NULL, raylib.KeyboardKey.KEY_NULL, .None }, // bottom edge
				
				{ {{ -RENDER_WIDTH / 2 + PAD_X_OFFSET_FROM_CENTER, 0 }, 0.5 * PAD_SIZE}, raylib.WHITE, raylib.KeyboardKey.W,  raylib.KeyboardKey.S,    .None }, // left pad
				{ {{ +RENDER_WIDTH / 2 - PAD_X_OFFSET_FROM_CENTER, 0 }, 0.5 * PAD_SIZE}, raylib.WHITE, raylib.KeyboardKey.UP, raylib.KeyboardKey.DOWN, .None }, // right pad
			};
			
			state.pads  = state.all_solids[4:];
			
			setup_new_game();
			
			state.mode = .Start_Menu;
			state.start_menu_current_active_item = START_MENU_DEFAULT_ACTIVE_ITEM;
			state.pause_menu_current_active_item = PAUSE_MENU_DEFAULT_ACTIVE_ITEM;
		}
		
		pause_key := raylib.KeyboardKey.ESCAPE;
		
		frame_counter := 0;
		should_quit   := false;
		for !raylib.WindowShouldClose() && !should_quit {
			
			// Every 5 seconds, if the audio device wasn't found, try again.
			if intrinsics.expect(!use_audio, false) && frame_counter % (60 * 5) == 0 {
				use_audio = raylib.IsAudioDeviceReady();
			}
			
			new_game_mode := state.mode;
			
			//~ Simulate.
			
			delta_time := raylib.GetFrameTime();
			
			if state.mode == .Start_Menu {
				//- "Simulate" start menu.
				
				// Menu navigation:
				if raylib.IsKeyPressed(raylib.KeyboardKey.DOWN) {
					increment_enum(&state.start_menu_current_active_item, +1);
					if use_audio { raylib.PlaySound(bump_sound); }
				} else if raylib.IsKeyPressed(raylib.KeyboardKey.UP) {
					increment_enum(&state.start_menu_current_active_item, -1);
					if use_audio { raylib.PlaySound(bump_sound); }
				}
				
				// Menu actions:
				if raylib.IsKeyPressed(raylib.KeyboardKey.ENTER) {
					
					switch state.start_menu_current_active_item {
						case .Play_PVP: {
							state.mode = .Playing;
							if use_audio { raylib.PlaySound(play_sound); }
							
							state.start_menu_current_active_item = START_MENU_DEFAULT_ACTIVE_ITEM;
						}
						case .Quit: { should_quit = true; }
					}
				}
			} else if state.mode == .Playing {
				if raylib.IsKeyPressed(pause_key) {
					state.mode = .Paused;
				}
				
				{
					// Move solids that can move.
					
					#no_bounds_check for &solid in state.all_solids {
						if raylib.IsKeyDown(solid.up_key) {
							solid.box.position.y = solid.box.position.y + PAD_SPEED;
							solid.box.position.y = min(solid.box.position.y, +0.5 * RENDER_HEIGHT - solid.box.half_size.y - SCREEN_BORDER_PADDING);
						}
						
						if raylib.IsKeyDown(solid.down_key) {
							solid.box.position.y = solid.box.position.y - PAD_SPEED;
							solid.box.position.y = max(solid.box.position.y, -0.5 * RENDER_HEIGHT + solid.box.half_size.y + SCREEN_BORDER_PADDING);
						}
					}
				}
				
				if state.gameplay_phase == .Play {
					if state.prev_gameplay_phase != state.gameplay_phase {
						// First frame of this phase.
						
						state.ball_color = raylib.WHITE;
					}
					
					// Make ball interact with solids.
					
					delta_position        := state.ball_direction * state.ball_speed;
					desired_ball_position := state.ball_box.position + delta_position;
					
					for solid, solid_index in state.all_solids {
						hit := false;
						clamped_delta_position := delta_position;
						
						distance : Vector2;
						distance.x = min(math.abs(state.ball_box.position.x + state.ball_box.half_size.x - (solid.box.position.x - solid.box.half_size.x)),
										 math.abs(state.ball_box.position.x - state.ball_box.half_size.x - (solid.box.position.x + solid.box.half_size.x)));
						distance.y = min(math.abs(state.ball_box.position.y + state.ball_box.half_size.y - (solid.box.position.y - solid.box.half_size.y)),
										 math.abs(state.ball_box.position.y - state.ball_box.half_size.y - (solid.box.position.y + solid.box.half_size.y)));
						
						signed_center_diff : Vector2;
						signed_center_diff.x = solid.box.position.x - state.ball_box.position.x;
						signed_center_diff.y = solid.box.position.y - state.ball_box.position.y;
						
						if distance.x < math.abs(delta_position.x) && signed_center_diff.x * delta_position.x > 0 && boxes_intersect(solid.box.position, solid.box.half_size, desired_ball_position, state.ball_box.half_size) {
							excess := math.abs(delta_position.x) - distance.x;
							excess *= math.sign(delta_position.x);
							
							clamped_delta_position.x = math.sign(signed_center_diff.x)*distance.x;
							clamped_delta_position.y = (clamped_delta_position.x * delta_position.y) / delta_position.x;
							delta_position.x = math.sign(signed_center_diff.x)*distance.x - excess;
							
							state.ball_direction.x *= -1;
							hit = true;
						}
						
						if distance.y < math.abs(delta_position.y) && signed_center_diff.y * delta_position.y > 0 && boxes_intersect(solid.box.position, solid.box.half_size, desired_ball_position, state.ball_box.half_size) {
							excess := math.abs(delta_position.y) - distance.y;
							excess *= math.sign(delta_position.y);
							
							clamped_delta_position.y = math.sign(signed_center_diff.y)*distance.y;
							clamped_delta_position.x = (clamped_delta_position.y * delta_position.x) / delta_position.y;
							delta_position.y = math.sign(signed_center_diff.y)*distance.y - excess;
							
							state.ball_direction.y *= -1;
							hit = true;
						}
						
						if hit {
							if solid.hit_action == .Player0_Scores || solid.hit_action == .Player1_Scores {
								
								delta_position = clamped_delta_position;
								
								restricted_start_directions : []Vector2;
								if solid.hit_action == .Player0_Scores {
									// if state.score[0] < MAX_SCORE { state.score[0] += 1; }
									restricted_start_directions = possible_start_directions[2:];
									
									state.index_of_player_who_scored = 0;
									// state.pads[0].box.half_size.y = max(state.pads[0].box.half_size.y - PAD_HEIGHT_DECREASE_AMOUNT, 0.5*PAD_MIN_SIZE_Y);
								} else {
									// if state.score[1] < MAX_SCORE { state.score[1] += 1; }
									restricted_start_directions = possible_start_directions[:2];
									
									state.index_of_player_who_scored = 1;
									// state.pads[1].box.half_size.y = max(state.pads[1].box.half_size.y - PAD_HEIGHT_DECREASE_AMOUNT, 0.5*PAD_MIN_SIZE_Y);
								}
								
								state.ball_start_direction = rand.choice(restricted_start_directions, &state.ball_start_direction_entropy);
								state.ball_direction = state.ball_start_direction;
								
								state.gameplay_phase_timer = -1.0;
							} else {
								state.ball_speed = min(state.ball_speed * BALL_SPEED_MULTIPLIER, BALL_SPEED_CAP);
								
								if use_audio { raylib.PlaySound(bump_sound); }
							}
							
							break;
						}
					}
					
					state.ball_box.position = state.ball_box.position + delta_position;
				} else if state.gameplay_phase == .Ready {
					if state.prev_gameplay_phase != state.gameplay_phase {
						// First frame of this phase.
						
						{
							// Update score and pad size for the player who scored.
							
							i := state.index_of_player_who_scored;
							
							if i >= 0 && i <= len(state.score) {
								if state.score[i] < MAX_SCORE { state.score[i] += 1; }
								state.pads[i].box.half_size.y = max(state.pads[i].box.half_size.y - PAD_HEIGHT_DECREASE_AMOUNT, 0.5*PAD_MIN_SIZE_Y);
							}
						}
						
						reset_board();
						if use_audio { raylib.PlaySound(play_sound); }
					}
				} else if state.gameplay_phase == .Blinking {
					when false {
						// Make the ball blink:
						
						// @Todo: Make blinking work. Maybe use math.fmod?
						is_visible := false;
						BALL_BLINK_DURATION :: 0.2;
						for ball_blink_timer := gameplay_phase_timer; ball_blink_timer >= 0 && !is_visible; ball_blink_timer -= BALL_BLINK_DURATION {
							if ball_blink_timer > BALL_BLINK_DURATION && ball_blink_timer < 2*BALL_BLINK_DURATION {
								is_visible = true;
							}
						}
						
						if is_visible { ball_color = raylib.WHITE; }
						else          { ball_color = raylib.BLANK; }
					}
					
					if state.prev_gameplay_phase != state.gameplay_phase {
						// First frame of this phase.
						
						if use_audio { raylib.PlaySound(kill_sound); }
					}
				}
				
				{
					//- Handle phase changes.
					
					state.prev_gameplay_phase = state.gameplay_phase;
					
					state.gameplay_phase_timer -= delta_time;
					if state.gameplay_phase_timer < 0 {
						increment_enum(&state.gameplay_phase);
						state.gameplay_phase_timer = gameplay_phase_durations[state.gameplay_phase];
					}
				}
			} else if state.mode == .Paused {
				//- "Simulate" pause menu.
				
				// Menu navigation:
				if raylib.IsKeyPressed(raylib.KeyboardKey.DOWN) {
					increment_enum(&state.pause_menu_current_active_item, +1);
					if use_audio { raylib.PlaySound(bump_sound); }
				} else if raylib.IsKeyPressed(raylib.KeyboardKey.UP) {
					increment_enum(&state.pause_menu_current_active_item, -1);
					if use_audio { raylib.PlaySound(bump_sound); }
				}
				
				// Menu actions:
				if raylib.IsKeyPressed(raylib.KeyboardKey.ENTER) {
					
					switch state.pause_menu_current_active_item {
						case .Resume: { state.mode = .Playing; }
						case .Restart: {
							setup_new_game();
							state.mode = .Playing;
						}
						case .Quit: {
							setup_new_game();
							state.mode = .Start_Menu;
						}
					}
					
					state.pause_menu_current_active_item = PAUSE_MENU_DEFAULT_ACTIVE_ITEM;
				}
			}
			
			//~ Render.
			
			raylib.BeginDrawing();
			raylib.ClearBackground(raylib.BLACK);
			
			FONT_SIZE    ::   50;
			TEXT_SPACING ::   10;
			
			raylib.BeginMode2D(camera);
			if state.mode == .Start_Menu {
				TITLE_FONT_SIZE :: FONT_SIZE * 1.5;
				TITLE_Y :: -140;
				
				title_string := cstring("Pong!");
				text_metrics := raylib.MeasureTextEx(raylib_default_font, title_string, TITLE_FONT_SIZE, TEXT_SPACING);
				
				centered_position := -0.5 * text_metrics;
				position := Vector2 { centered_position.x, TITLE_Y };
				
				raylib.DrawTextEx(raylib_default_font, title_string, position, TITLE_FONT_SIZE, TEXT_SPACING, raylib.WHITE);
				
				draw_menu(Start_Menu_Item, state.start_menu_current_active_item, raylib_default_font, FONT_SIZE, TEXT_SPACING, (0.5 * TITLE_FONT_SIZE) + TEXT_SPACING);
			} else if state.mode == .Playing || state.mode == .Paused {
				{
					//- Render solids.
					
					#no_bounds_check for solid in state.all_solids {
						render_position := Vector2 { solid.box.position.x, -solid.box.position.y };
						
						solid_rec : raylib.Rectangle;
						solid_rec.x      = render_position.x - solid.box.half_size.x;
						solid_rec.y      = render_position.y - solid.box.half_size.y;
						solid_rec.width  = 2 * solid.box.half_size.x;
						solid_rec.height = 2 * solid.box.half_size.y;
						
						raylib.DrawRectangleRec(solid_rec, solid.color);
					}
				}
				
				{
					//- Render divider line.
					
					VERTICAL_PADDING     :: 20.0;
					USABLE_RENDER_HEIGHT :: RENDER_HEIGHT - 2.0 * VERTICAL_PADDING;
					HALF_USABLE_RENDER_HEIGHT :: 0.5 * USABLE_RENDER_HEIGHT;
					
					DASH_COUNT           :: 20;
					DASH_HEIGHT          :: USABLE_RENDER_HEIGHT / (DASH_COUNT * 2.0 - 1.0);
					
					DASH_WIDTH           :: 2.0;
					DASH_X               :: -0.5 * DASH_WIDTH;
					
					y := cast(f32) -HALF_USABLE_RENDER_HEIGHT;
					for dash_index := 0; dash_index < DASH_COUNT; dash_index += 1 {
						dash_rec : raylib.Rectangle;
						dash_rec.x      = DASH_X;
						dash_rec.y      = y;
						dash_rec.width  = DASH_WIDTH;
						dash_rec.height = DASH_HEIGHT;
						
						raylib.DrawRectangleRec(dash_rec, raylib.WHITE);
						
						y += DASH_HEIGHT * 2;
					}
				}
				
				{
					//- Render ball.
					
					render_ball_position := Vector2 { state.ball_box.position.x, -state.ball_box.position.y }
					
					ball_rec : raylib.Rectangle;
					ball_rec.x      = render_ball_position.x - state.ball_box.half_size.x;
					ball_rec.y      = render_ball_position.y - state.ball_box.half_size.y;
					ball_rec.width  = 2 * state.ball_box.half_size.x;
					ball_rec.height = 2 * state.ball_box.half_size.y;
					
					raylib.DrawRectangleRec(ball_rec, state.ball_color);
				}
				
				{
					//- Render score.
					
					TEXT_Y       :: -200;
					TEXT_OFFSET  ::   50;
					
					#no_bounds_check for score_value, score_index in state.score {
						side := (score_index * 2) - 1;
						assert(side == -1 || side == 1);
						
						score_string := cstring_from_u64(score_value, context.temp_allocator);
						text_metrics := raylib.MeasureTextEx(raylib_default_font, score_string, FONT_SIZE, TEXT_SPACING);
						
						position := Vector2 { (f32(side) * TEXT_OFFSET), TEXT_Y };
						if side == -1 { position.x -= text_metrics.x; }
						
						raylib.DrawTextEx(raylib_default_font, score_string, position, FONT_SIZE, TEXT_SPACING, raylib.WHITE);
					}
				}
				
				if state.mode == .Paused {
					//- Render pause menu.
					
					{
						// Draw a black rectangle behind the menu to highlight the options
						RECT_WIDTH  :: RENDER_WIDTH  - 400;
						RECT_HEIGHT :: RENDER_HEIGHT - 380;
						
						rect : raylib.Rectangle;
						rect.x      = -RECT_WIDTH  * 0.5;
						rect.y      = -RECT_HEIGHT * 0.5;
						rect.width  =  RECT_WIDTH;
						rect.height =  RECT_HEIGHT;
						
						raylib.DrawRectangleRec(rect, raylib.BLACK);
					}
					
					draw_menu(Pause_Menu_Item, state.pause_menu_current_active_item, raylib_default_font, FONT_SIZE, TEXT_SPACING);
				}
			}
			raylib.EndMode2D();
			
			raylib.EndDrawing();
			
			runtime.free_all(context.temp_allocator);
			frame_counter += 1;
		}
	}
}

//~ Gameplay.

MAX_SCORE :: 999;

BALL_SIZE             :: Vector2 { 8, 8 };
BALL_START_SPEED      :: 3.0;
BALL_SPEED_MULTIPLIER :: 1.1;
BALL_SPEED_CAP        :: 6.4;

PAD_X_OFFSET_FROM_CENTER   :: 50;
PAD_SIZE                   :: Vector2 { 6, 80 };
PAD_MIN_SIZE_Y             :: 40;
PAD_SPEED                  :: 10;
PAD_HEIGHT_DECREASE_AMOUNT :: 5;

SCREEN_BORDER_PADDING :: 20;

gameplay_phase_durations := [len(Gameplay_Phase)]f32 {
	Gameplay_Phase.Ready    =  1.0,
	Gameplay_Phase.Play     =  math.INF_F32,
	Gameplay_Phase.Blinking =  1.2,
}

possible_start_directions := [?]Vector2 {
	{ +1, -1 },
	{ +1, +1 },
	{ -1, +1 },
	{ -1, -1 },
};

//~ State management.

setup_new_game :: proc() {
	state := &global_state;
	
	state.ball_start_direction = rand.choice(possible_start_directions[:], &state.ball_start_direction_entropy);
	state.ball_direction = state.ball_start_direction;
	reset_board();
	
	#no_bounds_check for &pad in state.pads {
		pad.box.position.y  = 0;
		pad.box.half_size.y = 0.5 * PAD_SIZE.y;
	}
	
	state.score = {};
	state.index_of_player_who_scored = -1;
	
	state.gameplay_phase = .Ready;
	state.gameplay_phase_timer = gameplay_phase_durations[state.gameplay_phase];
	
	allow_break();
}

reset_board :: proc() {
	state := &global_state;
	
	state.ball_speed = BALL_START_SPEED;
	state.ball_color = raylib.BLANK;
	state.ball_box.position = {};
}

Gameplay_Phase :: enum {
	Ready,
	Play,
	Blinking,
}

Game_Mode :: enum {
	Start_Menu,
	Playing,
	Paused,
}

global_state: Game_State;

Game_State :: struct {
	ball_start_direction_entropy : rand.Rand,
	ball_start_direction : Vector2,
	ball_direction : Vector2,
	ball_color : raylib.Color,
	ball_box : Box2,
	ball_speed : f32,
	
	all_solids : []Solid,
	pads : []Solid,
	
	score : [2]u64,
	index_of_player_who_scored : int,
	
	gameplay_phase : Gameplay_Phase,
	gameplay_phase_timer : f32,
	
	prev_gameplay_phase : Gameplay_Phase,
	
	mode : Game_Mode,
	prev_mode : Game_Mode,
	
	start_menu_current_active_item : Start_Menu_Item,
	pause_menu_current_active_item : Pause_Menu_Item,
}

//~ Start and Pause menus.

Start_Menu_Item :: enum { Play_PVP, Quit, }
Pause_Menu_Item :: enum { Resume, Restart, Quit, }

START_MENU_DEFAULT_ACTIVE_ITEM :: Start_Menu_Item.Play_PVP;
PAUSE_MENU_DEFAULT_ACTIVE_ITEM :: Pause_Menu_Item.Resume;

draw_menu :: proc($Items: typeid, current: Items, font: raylib.Font, font_size, text_spacing: f32, vertical_offset: f32 = 0) where intrinsics.type_is_enum(Items) {
	item_strings := cstring_slice_from_enum(Items, context.temp_allocator);
	
	replace :: proc "contextless" (cstr: ^cstring, old, new: byte) {
		str   := string(cstr^);
		bytes := transmute([]byte) str;
		
		#no_bounds_check for &b, index in bytes {
			if b == old {
				b = new;
			}
		}
		
		cstr^ = unsafe_string_to_cstring_contextless(str);
		
		// @Copypaste from core:strings. The only (meaningful) difference is it being marked as contextless.
		unsafe_string_to_cstring_contextless :: proc "contextless" (str: string) -> (res: cstring) {
			d := transmute(runtime.Raw_String) str;
			return cstring(d.data);
		}
	}
	
	#no_bounds_check for &item_string, item_index in item_strings {
		replace(&item_string, '_', ' ');
	}
	
	#no_bounds_check for item_string, item_index in item_strings {
		text_metrics := raylib.MeasureTextEx(font, item_string, font_size, text_spacing);
		centered_position := -0.5 * text_metrics;
		
		OFFSET_MULTIPLIER :: 1.3;
		position   := centered_position;
		position.y += (f32(item_index) - 0.5 * (len(Items) - 1)) * text_metrics.y * OFFSET_MULTIPLIER;
		
		position.y += vertical_offset;
		
		if item_index == cast(int) current {
			rect : raylib.Rectangle;
			rect.x      = position.x - 5;
			rect.y      = position.y - 5;
			rect.width  = text_metrics.x + 10;
			rect.height = text_metrics.y + 10;
			
			raylib.DrawRectangleRec(rect, raylib.WHITE);
			raylib.DrawTextEx(font, item_string, position, font_size, text_spacing, raylib.BLACK);
		} else {
			raylib.DrawTextEx(font, item_string, position, font_size, text_spacing, raylib.WHITE);
		}
	}
}

//~ Helpers.

slice_from_pointer_and_length :: proc "contextless" (p: $T/[^]$E, n: int) -> []E {
	return transmute([]E) runtime.Raw_Slice{ p, n };
}

cstring_from_u64 :: proc(u: u64, allocator := context.allocator, loc := #caller_location) -> (result: cstring, error: runtime.Allocator_Error) #optional_allocator_error {
	MAX_U64_CHARACTERS :: 20;
	builder := strings.builder_make(0, MAX_U64_CHARACTERS + 1, allocator, loc) or_return;
	strings.write_u64(&builder, u);
	result = cstring_from_builder(&builder);
	return result, .None;
}

cstring_from_enum :: proc(v: $T, allocator := context.allocator, loc := #caller_location) -> (result: cstring, error: runtime.Allocator_Error) where intrinsics.type_is_enum(T) #optional_allocator_error {
	s := reflect.enum_string(v);
	return strings.clone_to_cstring(s, allocator, loc);
}

cstring_slice_from_enum :: proc($T: typeid, allocator := context.allocator, loc := #caller_location) -> (result: []cstring, error: runtime.Allocator_Error) where intrinsics.type_is_enum(T) #optional_allocator_error {
	result = make([]cstring, len(T), allocator, loc) or_return;
	
	#no_bounds_check for value, index in T {
		s := reflect.enum_string(value);
		result[index] = strings.clone_to_cstring(s, allocator, loc) or_return;
	}
	
	return result, .None;
}

cstring_from_builder :: proc(builder: ^strings.Builder) -> (result: cstring, success: bool) #optional_ok {
	if builder != nil {
		bytes_written := strings.write_byte(builder, 0);
		if bytes_written > 0 {
			result  = strings.unsafe_string_to_cstring(strings.to_string(builder^));
			success = true;
		}
	}
	
	return result, success;
}

increment_enum :: proc "contextless" (value: ^$T, amount := 1) where intrinsics.type_is_enum(T) {
	v := value^;
	i := cast(int) v;
	i += amount;
	n := len(T);
	for i > n - 1 do i -= n;
	for i < 0     do i += n;
	v  = cast(T) i;
	value^ = v;
}

boxes_intersect :: proc "contextless" (p1, h1, p2, h2: [2]f32) -> bool {
	res_x  := (math.abs(p1.x - p2.x) < h1.x + h2.x);
	res_y  := (math.abs(p1.y - p2.y) < h1.y + h2.y);
	
	result := res_x && res_y;
	return result;
}

//~ Sound synthesis.

Oscillator_Kind :: enum { Square, Sine, Triangle, Saw, Noise }

Envelope :: struct {
	attack_seconds,
	decay_seconds,
	release_seconds: f64,
	
	sustain_amplitude,
	start_amplitude: f64,
}

DEFAULT_ENVELOPE :: Envelope {
	0.05,
	0.01,
	0.10,
	
	0.80,
	1.00,
}

NO_ENVELOPE :: Envelope {
	0.00,
	0.00,
	0.00,
	
	1.00,
	1.00,
}

concatenate_waves :: proc(waves: []raylib.Wave) -> (result: raylib.Wave, success: bool) #optional_ok {
	if len(waves) > 0 {
		formats_match := true;
		#no_bounds_check for wave_index in 1..<len(waves) {
			if (waves[wave_index].sampleRate != waves[0].sampleRate ||
				waves[wave_index].sampleSize != waves[0].sampleSize ||
				waves[wave_index].channels   != waves[0].channels) {
				formats_match = false;
				break;
			}
		}
		
		if formats_match {
			samples_per_second := cast(int) waves[0].sampleRate;
			bits_per_sample    := cast(int) waves[0].sampleSize;
			channel_count      := cast(int) waves[0].channels;
			
			total_frame_count := 0;
			#no_bounds_check for wave in waves {
				total_frame_count += cast(int) wave.frameCount;
			}
			
			bytes_per_sample := bits_per_sample / 8;
			data_size        := bytes_per_sample * total_frame_count * channel_count;
			data, make_error := make([]byte, data_size);
			
			if make_error == .None {
				written_frames := 0;
				#no_bounds_check for wave in waves {
					frame_count := cast(int) wave.frameCount;
					wave_data := slice_from_pointer_and_length(cast([^]byte) wave.data, frame_count);
					
					copy(data[written_frames : written_frames + frame_count], wave_data);
					
					written_frames += frame_count;
				}
				
				result.frameCount = cast(u32) total_frame_count;
				result.sampleRate = cast(u32) samples_per_second;
				result.sampleSize = cast(u32) bits_per_sample;
				result.channels   = cast(u32) channel_count;
				result.data       = raw_data(data);
				
				success = true;
			}
		}
	} else {
		success = true;
	}
	
	return result, success;
}

make_wave :: proc(hold_seconds: f64, samples_per_second, bits_per_sample, channel_count: int, kind: Oscillator_Kind, envelope := DEFAULT_ENVELOPE, frequency_multiplier := 1.0) -> (raylib.Wave, bool) #optional_ok {
	wave : raylib.Wave;
	success := false;
	
	if is_bit_depth_valid(bits_per_sample) && is_channel_count_valid(channel_count) {
		sustain_seconds  := get_sustain_seconds(envelope, hold_seconds);
		total_seconds    := hold_seconds + sustain_seconds;
		frame_count      := cast(int) (cast(f64) samples_per_second * total_seconds);
		
		bytes_per_sample := bits_per_sample / 8;
		data_size        := bytes_per_sample * frame_count * channel_count;
		data, make_error := make([]byte, data_size);
		
		if make_error == .None {
			FREQUENCY :: 256; // The frequency controls the pitch.
			AMPLIFIER := f64(max_signed(bytes_per_sample));
			
			frequency := FREQUENCY * frequency_multiplier;
			
			// Given a number of bytes, returns the maximum signed integer number representable with that number of bytes.
			max_signed :: proc(byte_count: int) -> int {
				shift_down_bytes := 8 - byte_count;
				shift_down_bits  := shift_down_bytes * 8;
				
				result := cast(int) ((max(u64) >> uint(shift_down_bits)) / 2);
				return result;
			}
			
			wave_period      := samples_per_second / cast(int) frequency; 
			half_wave_period := wave_period / 2; 
			sample_index     := 0;
			
			for byte_index := 0; byte_index < len(data); byte_index += bytes_per_sample * channel_count {
				sample_value : i32;
				{
					normalized_t := cast(f64) sample_index / cast(f64) wave_period;
					
					normalized_sample_value : f64;
					switch kind {
						case .Square: {
							//- Square wave:
							
							sample_index %= wave_period;
							normalized_sample_value = (sample_index > half_wave_period) ? 1 : -1;
						}
						
						case .Sine: {
							//- Sine wave:
							
							normalized_sample_value = math.sin(math.TAU * normalized_t);
						}
						
						case .Triangle: {
							//- Triangle wave:
							
							normalized_sample_value  = math.asin(math.sin(math.TAU * normalized_t));
							normalized_sample_value *= (2.0 / math.PI); // arcsin() returns numbers in the range [-PI/2, PI/2]; This maps it to the range [-1, 1].
						}
						
						case .Saw: {
							//- Saw wave:
							
							PERIOD := 1.0 / frequency;
							normalized_sample_value  = math.mod_f64(normalized_t, PERIOD);
							normalized_sample_value *= 2.0 * frequency; // mod(t, T) returns a number in the range [0, T]; this maps it to the range [0, 2*F*T] = [0, 2];
							normalized_sample_value -= 1;               // Finally it is shifted to [-1, 1].
						}
						
						case .Noise: {
							//- Random noise:
							
							normalized_sample_value = rand.float64_range(-1, 1); // @Todo: high param of range() is exclusive. Make a version where it's inclusive.
						}
					}
					
					seconds_since_start := cast(f64) sample_index / cast(f64) frame_count;
					amplitude           := get_amplitude(envelope, sustain_seconds, seconds_since_start);
					sample_value = cast(i32) (normalized_sample_value * amplitude * AMPLIFIER);
					
					sample_index += 1;
				}
				
				sample_value_split : [4]byte = {
					cast(byte) ((sample_value >>  0) & 0xFF),
					cast(byte) ((sample_value >>  8) & 0xFF),
					cast(byte) ((sample_value >> 16) & 0xFF),
					cast(byte) ((sample_value >> 24) & 0xFF),
				};
				
				#no_bounds_check for channel_index := 0; channel_index < channel_count; channel_index += 1 {
					offset := byte_index + (bytes_per_sample * channel_index);
					bytes_copied := copy(data[offset:offset + bytes_per_sample], sample_value_split[:bytes_per_sample]);
					assert(bytes_copied == bytes_per_sample);
				}
			}
			
			wave.frameCount = cast(u32) frame_count;
			wave.sampleRate = cast(u32) samples_per_second;
			wave.sampleSize = cast(u32) bits_per_sample;
			wave.channels   = cast(u32) channel_count;
			wave.data       = raw_data(data);
			
			success = true;
			
			get_amplitude :: proc(envelope: Envelope, sustain_seconds, time: f64) -> (amplitude: f64) {
				start_timestamp := 0.0;
				lifetime := time - start_timestamp;
				
				if        lifetime <= envelope.attack_seconds {
					amplitude = (lifetime / envelope.attack_seconds) * envelope.start_amplitude;
				} else if lifetime <= envelope.attack_seconds + envelope.decay_seconds {
					amplitude = ((lifetime - envelope.attack_seconds) / envelope.decay_seconds) * (envelope.sustain_amplitude - envelope.start_amplitude) + envelope.start_amplitude;
				} else if lifetime <= envelope.attack_seconds + envelope.decay_seconds + sustain_seconds {
					amplitude = envelope.sustain_amplitude;
				} else {
					amplitude = (lifetime / envelope.release_seconds) * (0.0 - envelope.sustain_amplitude) + envelope.sustain_amplitude;
				}
				
				AMPLITUDE_EPSILON :: 0.0001;
				if amplitude < AMPLITUDE_EPSILON { amplitude = 0.0; }
				
				return amplitude;
			}
		}
		
		get_sustain_seconds :: proc(envelope: Envelope, hold_seconds: f64) -> (sustain_seconds: f64) {
			sustain_seconds = hold_seconds - (envelope.attack_seconds + envelope.decay_seconds);
			sustain_seconds = max(sustain_seconds, 0);
			
			return sustain_seconds;
		}
	}
	
	is_bit_depth_valid     :: proc(depth: int) -> bool { return depth == 8 || depth == 16 || depth == 32; }
	is_channel_count_valid :: proc(count: int) -> bool { return count == 1 || count == 2; }
	
	return wave, success;
}

make_sound :: proc(hold_seconds: f64, samples_per_second, bits_per_sample, channel_count: int, kind: Oscillator_Kind, envelope := DEFAULT_ENVELOPE, frequency_multiplier := 1.0) -> (sound: raylib.Sound, success: bool) #optional_ok {
	wave := make_wave(hold_seconds, samples_per_second, bits_per_sample, channel_count, kind, envelope, frequency_multiplier) or_return;
	sound = raylib.LoadSoundFromWave(wave);
	
	// If we got here, it means the arguments to make_wave() were valid and the wave allocation was successful.
	// This means that the wave needs to be valid and playable by raylib, otherwise there's a bug in make_wave().
	// Let's check for that:
	assert(raylib.IsSoundReady(sound));
	return sound, true;
}

allow_break :: proc "contextless" () { ; }
