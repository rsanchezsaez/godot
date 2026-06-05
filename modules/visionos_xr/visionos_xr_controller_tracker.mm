/**************************************************************************/
/*  visionos_xr_controller_tracker.mm                                     */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#ifdef VISIONOS_ENABLED

// Rename Godot's `Key` to `GodotKey` so it doesn't clash with GCPhysicalInputElementCollection's `Key` template parameter; unused in this file.
#define Key GodotKey
#include "visionos_xr_controller_tracker.h"

#include "visionos_simd_helpers.h"
#include "visionos_xr_interface.h"

#include "core/error/error_macros.h"
#include "core/object/class_db.h"
#include "core/os/os.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_server_globals.h"

#include "platform/visionos/godot_app_delegate_service_visionos.h"
#undef Key

#include <ARKit/ARKit.h>
#include <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>

// Button mapping logic
namespace {
struct ButtonMapping {
	GCInputButtonName gc_input;
	const char *action_name;
	const char *click_action_name;
};

static const ButtonMapping button_mappings[] = {
	{ GCInputGripButton, "grip_button", "grip_button_click" },
	{ GCInputTrigger, "trigger", "trigger_click" },
	{ GCInputButtonA, "button_a", nullptr },
	{ GCInputButtonB, "button_b", nullptr },
	{ GCInputButtonMenu, "button_menu", nullptr },
	{ GCInputThumbstickButton, "button_thumbstick", nullptr },
};
} //namespace

struct VisionOSXRControllerTracker::Helpers {
	static void process_button(GCControllerLiveInput *input, const ButtonMapping &button_mapping,
			Ref<XRControllerTracker> controller_tracker, VisionOSXRControllerTracker::Events &events) {
		auto *button = input.buttons[button_mapping.gc_input];
		if (button != nullptr) {
			events.push_back({ .controller_tracker = controller_tracker,
					.action_name = button_mapping.action_name,
					.value = button.pressedInput.value });
			if (button_mapping.click_action_name != nullptr) {
				events.push_back({ .controller_tracker = controller_tracker,
						.action_name = button_mapping.click_action_name,
						.value = button.pressedInput.isPressed });
			}
		}
	}

	static void process_thumbstick(GCControllerLiveInput *input, Ref<XRControllerTracker> controller_tracker,
			VisionOSXRControllerTracker::Events &events) {
		auto *thumbstick = input.dpads[GCInputThumbstick];
		if (thumbstick != nullptr) {
			float x_value = thumbstick.xAxis.value;
			float y_value = thumbstick.yAxis.value;
			events.push_back({ .controller_tracker = controller_tracker,
					.action_name = "primary",
					.value = Vector2(x_value, y_value) });
		}
	}
};

VisionOSXRControllerTracker::VisionOSXRControllerTracker() {}

void VisionOSXRControllerTracker::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_tracking_correction", "correction"), &VisionOSXRControllerTracker::set_tracking_correction);
}

VisionOSXRControllerTracker::~VisionOSXRControllerTracker() {
	// and make sure we cleanup if we haven't already
	if (is_initialized()) {
		uninitialize();
	};
}

StringName VisionOSXRControllerTracker::get_name() const {
	return VisionOSXRControllerTracker::name();
}

uint32_t VisionOSXRControllerTracker::get_capabilities() const {
	return XRInterface::XR_NONE;
}

uint32_t VisionOSXRControllerTracker::get_view_count() {
	return 0;
}

XRInterface::TrackingStatus VisionOSXRControllerTracker::get_tracking_status() const {
	return tracking_state;
}

bool VisionOSXRControllerTracker::is_initialized() const {
	return initialized;
}

bool VisionOSXRControllerTracker::initialize() {
	if (initialized) {
		ERR_PRINT("VisionOSXRControllerTracker already initialized");
		return true;
	}

	ERR_FAIL_NULL_V_MSG(xr_interface, false, "VisionOSXRControllerTracker: xr_interface not set.");

	// Ensure the shared ARKit session exists (idempotent), so this tracker can be
	// initialized standalone from GDScript without the compositor services renderer.
	xr_interface->ensure_session();

	_accessory_lock = OS_UNFAIR_LOCK_INIT;
	_accessories_to_add = ar_accessories_create();

	// Scan existing controllers
	for (GCController *controller in GCController.controllers) {
		init_for_controller(controller);
	}

	setup_controller_notifications();

	ar_session_t shared_session = xr_interface->get_ar_session();
	ERR_FAIL_NULL_V_MSG(shared_session, false, "VisionOSXRControllerTracker: shared ARKit session not available.");

	ar_session_request_authorization(shared_session, ar_authorization_type_accessory_tracking,
			^(ar_authorization_results_t authorization_results, ar_error_t error) {
				if (error) {
					ERR_PRINT("VisionOSXRControllerTracker : Error requesting Accessory Tracking authorization.");
					return;
				}

				ar_authorization_results_enumerate_results(authorization_results,
						^bool(ar_authorization_result_t authorization_result) {
							if (ar_authorization_result_get_authorization_type(authorization_result) & ar_authorization_type_accessory_tracking) {
								switch (ar_authorization_result_get_status(authorization_result)) {
									case ar_authorization_status_denied:
										ERR_PRINT("VisionOSXRControllerTracker : Accessory Tracking authorization has been denied...");
										break;
									case ar_authorization_status_allowed:
										break;
									default:
										break;
								}
							}
							return true;
						});
			});

	left_controller_tracker.instantiate();
	left_controller_tracker->set_tracker_hand(XRPositionalTracker::TRACKER_HAND_LEFT);
	left_controller_tracker->set_tracker_name("/user/controller_tracker/left");
	left_controller_tracker->set_tracker_desc("VisionOS Left Controller");
	XRServer::get_singleton()->add_tracker(left_controller_tracker);

	right_controller_tracker.instantiate();
	right_controller_tracker->set_tracker_hand(XRPositionalTracker::TRACKER_HAND_RIGHT);
	right_controller_tracker->set_tracker_name("/user/controller_tracker/right");
	right_controller_tracker->set_tracker_desc("VisionOS Right Controller");
	XRServer::get_singleton()->add_tracker(right_controller_tracker);

	initialized = true;
	return initialized;
}

void VisionOSXRControllerTracker::uninitialize() {
	os_unfair_lock_lock(&_accessory_lock);

	if (!initialized) {
		os_unfair_lock_unlock(&_accessory_lock);
		return;
	}

	// Remove our controller tracking provider from the shared session
	if (controller_tracking_provider != nullptr && xr_interface != nullptr) {
		xr_interface->remove_data_provider(controller_tracking_provider);
		controller_tracking_provider = nullptr;
	}

	XRServer *xr_server = XRServer::get_singleton();
	if (xr_server != nullptr) {
		if (left_controller_tracker.is_valid()) {
			xr_server->remove_tracker(left_controller_tracker);
			left_controller_tracker.unref();
		}
		if (right_controller_tracker.is_valid()) {
			xr_server->remove_tracker(right_controller_tracker);
			right_controller_tracker.unref();
		}
		initialized = false;
	}

	if (_accessories_to_add != nullptr) {
		// Release the accessories collection if needed
		_accessories_to_add = nullptr;
	}

	left_controller_anchor = nullptr;
	right_controller_anchor = nullptr;
	left_gc_controller = nullptr;
	right_gc_controller = nullptr;
	left_haptic_engine = nullptr;
	right_haptic_engine = nullptr;

	os_unfair_lock_unlock(&_accessory_lock);

	cleanup_controller_notifications();
}

void VisionOSXRControllerTracker::run_provider() {
	os_unfair_lock_lock(&_accessory_lock);
	run_provider_locked();
	os_unfair_lock_unlock(&_accessory_lock);
}

void VisionOSXRControllerTracker::run_provider_locked() {
	if (!initialized || xr_interface == nullptr) {
		return;
	}

	// Remove old provider from the shared session if any
	if (controller_tracking_provider != nullptr) {
		xr_interface->remove_data_provider(controller_tracking_provider);
		controller_tracking_provider = nullptr;
	}

	ar_accessory_tracking_configuration_t accessory_tracking_configuration = ar_accessory_tracking_configuration_create();

	if (ar_accessory_tracking_provider_is_supported() && _accessories_to_add != nullptr && ar_accessories_get_count(_accessories_to_add) != 0) {
		ar_accessories_t accessories = ar_accessories_create();
		ar_accessories_add_accessories(accessories, _accessories_to_add);
		ar_accessory_tracking_configuration_set_accessories(accessory_tracking_configuration, _accessories_to_add);
	}

	controller_tracking_provider = ar_accessory_tracking_provider_create(accessory_tracking_configuration);
	xr_interface->add_data_provider(controller_tracking_provider);
}

void VisionOSXRControllerTracker::init_for_controller(GCController *controller) {
	ar_accessory_load_from_device(controller,
			^(id<GCDevice> _Nonnull device, bool success, ar_error_t _Nullable error, ar_accessory_t _Nullable accessory) {
				if (!success) {
					ERR_PRINT("Error loading from GCDevice...\n");
				} else {
					os_unfair_lock_lock(&_accessory_lock);
					ar_accessory_chirality_t chirality = ar_accessory_get_inherent_chirality(accessory);
					if (chirality == ar_accessory_chirality_left) {
						left_gc_controller = controller;
						if (left_gc_controller != nullptr && left_gc_controller.haptics != nullptr) {
							left_haptic_engine = [left_gc_controller.haptics createEngineWithLocality:GCHapticsLocalityDefault];
						}
						ar_accessories_add_accessory(_accessories_to_add, accessory);
					} else if (chirality == ar_accessory_chirality_right) {
						right_gc_controller = controller;
						if (right_gc_controller != nullptr && right_gc_controller.haptics != nullptr) {
							right_haptic_engine = [right_gc_controller.haptics createEngineWithLocality:GCHapticsLocalityDefault];
						}
						ar_accessories_add_accessory(_accessories_to_add, accessory);
					} else {
						ERR_PRINT("Accessory with undefined chirality...");
					}
					os_unfair_lock_unlock(&_accessory_lock);
					run_provider();
				}
			});
}

void VisionOSXRControllerTracker::setup_controller_notifications() {
	controller_observer = [NSNotificationCenter.defaultCenter
			addObserverForName:GCControllerDidConnectNotification
						object:nil
						 queue:nil
					usingBlock:^(NSNotification *notification) {
						GCController *controller = (GCController *)notification.object;
						init_for_controller(controller);
					}];

	controller_disconnect_observer = [NSNotificationCenter.defaultCenter
			addObserverForName:GCControllerDidDisconnectNotification
						object:nil
						 queue:nil
					usingBlock:^(NSNotification *notification) {
						GCController *controller = (GCController *)notification.object;
						handle_controller_disconnect(controller);
					}];
}

void VisionOSXRControllerTracker::handle_controller_disconnect(GCController *controller) {
	os_unfair_lock_lock(&_accessory_lock);

	if (left_gc_controller != nullptr && left_gc_controller == controller) {
		if (left_controller_anchor != nullptr) {
			ar_accessory_t accessory_left = ar_accessory_anchor_get_accessory(left_controller_anchor);
			if (accessory_left != nullptr) {
				ar_accessories_remove_accessory(_accessories_to_add, accessory_left);
				left_controller_anchor = nullptr;
				left_gc_controller = nullptr;
				left_haptic_engine = nullptr;
				run_provider_locked();
			}
		}
	} else if (right_gc_controller != nullptr && right_gc_controller == controller) {
		if (right_controller_anchor != nullptr) {
			ar_accessory_t accessory_right = ar_accessory_anchor_get_accessory(right_controller_anchor);
			if (accessory_right != nullptr) {
				ar_accessories_remove_accessory(_accessories_to_add, accessory_right);
				right_controller_anchor = nullptr;
				right_gc_controller = nullptr;
				right_haptic_engine = nullptr;
				run_provider_locked();
			}
		}
	}

	os_unfair_lock_unlock(&_accessory_lock);
}

void VisionOSXRControllerTracker::cleanup_controller_notifications() {
	if (controller_observer) {
		[NSNotificationCenter.defaultCenter removeObserver:controller_observer];
		controller_observer = nullptr;
	}

	if (controller_disconnect_observer) {
		[NSNotificationCenter.defaultCenter removeObserver:controller_disconnect_observer];
		controller_disconnect_observer = nullptr;
	}
}

Dictionary VisionOSXRControllerTracker::get_system_info() {
	Dictionary dict;
	dict[SNAME("XRRuntimeName")] = String("Godot visionOS Controller Tracker");
	dict[SNAME("XRRuntimeVersion")] = String("1.0");
	return dict;
}

Transform3D VisionOSXRControllerTracker::get_camera_transform() {
	return Transform3D();
}

Transform3D VisionOSXRControllerTracker::get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform) {
	return Transform3D();
}

Projection VisionOSXRControllerTracker::get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far) {
	return Projection();
}

Size2 VisionOSXRControllerTracker::get_render_target_size() {
	return Size2();
}

void VisionOSXRControllerTracker::update_controller_from_anchor(Ref<XRControllerTracker> controller_tracker,
		ar_accessory_anchor_t controller_anchor,
		GCController *gc_controller,
		bool is_left_hand,
		VisionOSXRControllerTracker::Events &events) {
	simd_float4x4 origin_from_controller_anchor_simd = ar_anchor_get_origin_from_anchor_transform(controller_anchor);
	Transform3D origin_from_controller_anchor = MTL::simd_to_transform3D(origin_from_controller_anchor_simd);

	// Apply coordinate system conversion from ARKit space to Godot humanoid space
	real_t rotation_angle = (is_left_hand ? -1 : 1) * Math::PI * 0.5;
	const Quaternion rotation_x(Vector3(1, 0, 0), rotation_angle);
	const Quaternion rotation_y(Vector3(0, 1, 0), rotation_angle);
	const Quaternion controller_position_axis_adjustment = rotation_x * rotation_y;
	origin_from_controller_anchor.basis = origin_from_controller_anchor.basis * controller_position_axis_adjustment;

	origin_from_controller_anchor.origin =
			tracking_correction.basis.xform(origin_from_controller_anchor.origin) + tracking_correction.origin;
	Quaternion correction_rot = tracking_correction.basis.get_rotation_quaternion();
	origin_from_controller_anchor.basis = Basis(correction_rot) * origin_from_controller_anchor.basis;

	controller_tracker->set_pose("default", origin_from_controller_anchor, Vector3(), Vector3());

	// Button inputs
	if (gc_controller && gc_controller.input) {
		GCControllerLiveInput *input = gc_controller.input;

		for (const auto &mapping : button_mappings) {
			Helpers::process_button(input, mapping, controller_tracker, events);
		}
		Helpers::process_thumbstick(input, controller_tracker, events);
	}
}

void VisionOSXRControllerTracker::trigger_haptic_pulse(const String &p_action_name, const StringName &p_tracker_name, double p_frequency, double p_amplitude, double p_duration_sec, double p_delay_sec) {
	os_unfair_lock_lock(&_accessory_lock);

	GCController *target_controller = nullptr;
	CHHapticEngine *target_engine = nullptr;

	if (p_tracker_name == left_controller_tracker->get_tracker_name()) {
		target_controller = left_gc_controller;
		target_engine = left_haptic_engine;
	} else if (p_tracker_name == right_controller_tracker->get_tracker_name()) {
		target_controller = right_gc_controller;
		target_engine = right_haptic_engine;
	}

	if (target_controller == nullptr) {
		ERR_PRINT("Controller is nil. No haptics supported..");
		os_unfair_lock_unlock(&_accessory_lock);
		return;
	}

	if (target_engine == nullptr) {
		ERR_PRINT("Haptic engine is nil...");
		os_unfair_lock_unlock(&_accessory_lock);
		return;
	}

	float intensity = CLAMP(p_amplitude, 0.0f, 1.0f);
	float sharpness = CLAMP(p_frequency / 1000.0f, 0.0f, 1.0f);

	NSError *error = nil;

	[target_engine startAndReturnError:&error];
	if (error) {
		ERR_PRINT(vformat("Failed to start engine: %s", [error.localizedDescription UTF8String]));
		os_unfair_lock_unlock(&_accessory_lock);
		return;
	}

	CHHapticEventParameter *intensityParam = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:intensity];
	CHHapticEventParameter *sharpnessParam = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness];

	CHHapticEvent *event;
	if (p_duration_sec > 0) {
		event = [[CHHapticEvent alloc]
				initWithEventType:CHHapticEventTypeHapticContinuous
					   parameters:@[ intensityParam, sharpnessParam ]
					 relativeTime:0.0
						 duration:p_duration_sec];
	} else {
		event = [[CHHapticEvent alloc]
				initWithEventType:CHHapticEventTypeHapticTransient
					   parameters:@[ intensityParam, sharpnessParam ]
					 relativeTime:0.0];
	}

	CHHapticPattern *pattern = [[CHHapticPattern alloc]
			 initWithEvents:@[ event ]
			parameterCurves:@[]
					  error:&error];

	if (error) {
		ERR_PRINT(vformat("Failed to create a haptics pattern: %s", [error.localizedDescription UTF8String]));
		os_unfair_lock_unlock(&_accessory_lock);
		return;
	}

	id<CHHapticPatternPlayer> player = [target_engine createPlayerWithPattern:pattern error:&error];
	if (error) {
		ERR_PRINT(vformat("Failed to create a haptics player: %s", [error.localizedDescription UTF8String]));
		os_unfair_lock_unlock(&_accessory_lock);
		return;
	}

	[player startAtTime:CHHapticTimeImmediate error:&error];
	if (error) {
		ERR_PRINT(vformat("Failed to start a haptics playback: %s", [error.localizedDescription UTF8String]));
	}

	// For transient events, we can stop the engine immediately after starting playback
	if (p_duration_sec <= 0) {
		// Transient - can stop engine soon after
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[target_engine stopWithCompletionHandler:^(NSError *_Nullable error) {
				if (error) {
					ERR_PRINT(vformat("Error stopping haptics engine: %s", [error.localizedDescription UTF8String]));
				}
			}];
		});
	} else {
		// Continuous - stop after duration + small buffer
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((p_duration_sec + 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[target_engine stopWithCompletionHandler:^(NSError *_Nullable error) {
				if (error) {
					ERR_PRINT(vformat("Error stopping haptics engine: %s", [error.localizedDescription UTF8String]));
				}
			}];
		});
	}

	os_unfair_lock_unlock(&_accessory_lock);
}

void VisionOSXRControllerTracker::update_controller_trackers_from_arkit() {
	if (!initialized) {
		return;
	}

	if (!os_unfair_lock_trylock(&_accessory_lock)) {
		// give up on this frame!
		return;
	}

	// Get timing information
	CFTimeInterval trackable_anchor_time = 0;

	GDTRenderMode app_delegate_render_mode = GDTAppDelegateServiceVisionOS.renderMode;
	if (app_delegate_render_mode == GDTRenderModeCompositorServices) {
		if (xr_interface != nullptr && xr_interface->is_initialized()) {
			cp_frame_timing_t frame_timing = xr_interface->get_current_timing();
			if (frame_timing != nullptr) {
				trackable_anchor_time = cp_time_to_cf_time_interval(cp_frame_timing_get_trackable_anchor_time(frame_timing));
			}
		}
	} else {
		// Get timing from UIScene for standalone mode
		UIWindowScene *windowScene = nil;
		for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
			if ([scene isKindOfClass:[UIWindowScene class]]) {
				UIWindowScene *windowSceneCandidate = (UIWindowScene *)scene;
				if (windowSceneCandidate.activationState == UISceneActivationStateForegroundActive) {
					windowScene = windowSceneCandidate;
					break;
				}
			}
		}
		if (windowScene != nil) {
			UIUpdateInfo *ui_update_info = [UIUpdateInfo currentUpdateInfoForWindowScene:windowScene];
			trackable_anchor_time = ui_update_info.estimatedPresentationTime;
		}
	}

	__block Events events;

	if (controller_tracking_provider != nullptr) {
		ar_accessory_anchors_t accessory_anchors = ar_accessory_tracking_provider_get_latest_anchors(controller_tracking_provider);

		__block bool left_found = false;
		__block bool right_found = false;

		if (accessory_anchors != nullptr) {
			ar_accessory_anchors_enumerate_anchors(accessory_anchors, ^bool(ar_accessory_anchor_t accessory_anchor) {
				ar_data_provider_state_t provider_state = ar_data_provider_get_state((ar_data_provider_t)controller_tracking_provider);
				if (provider_state != ar_data_provider_state_running) {
					return true;
				}

				if (!ar_trackable_anchor_is_tracked(accessory_anchor)) {
					return true;
				}

				// Predict anchor at target time if we have timing info
				if (trackable_anchor_time != 0) {
					bool success = ar_accessory_tracking_provider_predict_anchor_at_timestamp(
							controller_tracking_provider, accessory_anchor, trackable_anchor_time, accessory_anchor);
					if (!success) {
						return true;
					}
				}

				ar_accessory_t accessory = ar_accessory_anchor_get_accessory(accessory_anchor);
				ar_accessory_chirality_t chirality = ar_accessory_get_inherent_chirality(accessory);

				if (chirality == ar_accessory_chirality_left && !left_found) {
					left_controller_anchor = accessory_anchor;
					update_controller_from_anchor(left_controller_tracker, left_controller_anchor, left_gc_controller, true, events);
					left_found = true;
				} else if (chirality == ar_accessory_chirality_right && !right_found) {
					right_controller_anchor = accessory_anchor;
					update_controller_from_anchor(right_controller_tracker, right_controller_anchor, right_gc_controller, false, events);
					right_found = true;
				}
				return true;
			});
		}
		tracking_state = (left_found || right_found) ? XRInterface::XR_NORMAL_TRACKING : XRInterface::XR_NOT_TRACKING;
	}

	os_unfair_lock_unlock(&_accessory_lock);

	// Processing events outside of the lock, to avoid re-entering the lock
	for (VisionOSXRControllerTracker::Event &event : events) {
		event.controller_tracker->set_input(event.action_name, event.value);
	}
}

void VisionOSXRControllerTracker::process() {
	if (!initialized) {
		return;
	}
	update_controller_trackers_from_arkit();
}

Vector<RenderingServerTypes::BlitToScreen> VisionOSXRControllerTracker::post_draw_viewport(RID p_render_target, const Rect2 &p_screen_rect) {
	_THREAD_SAFE_METHOD_
	return Vector<RenderingServerTypes::BlitToScreen>();
}

void VisionOSXRControllerTracker::set_tracking_correction(const Transform3D &p_correction) {
	tracking_correction = p_correction;
}

#endif // VISIONOS_ENABLED
