/**************************************************************************/
/*  visionos_xr_hand_tracker.mm                                           */
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

#include "visionos_xr_hand_tracker.h"

#include "visionos_simd_helpers.h"
#include "visionos_xr_interface.h"

#include "core/input/input.h"
#include "core/os/os.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_server_globals.h"

#include "platform/visionos/godot_app_delegate_service_visionos.h"

VisionOSXRHandTracker::VisionOSXRHandTracker() {}

VisionOSXRHandTracker::~VisionOSXRHandTracker() {
	// and make sure we cleanup if we haven't already
	if (is_initialized()) {
		uninitialize();
	};
}

StringName VisionOSXRHandTracker::get_name() const {
	return VisionOSXRHandTracker::name();
}

uint32_t VisionOSXRHandTracker::get_capabilities() const {
	return XRInterface::XR_NONE;
}

uint32_t VisionOSXRHandTracker::get_view_count(RID p_render_target) {
	return 0;
}

XRInterface::TrackingStatus VisionOSXRHandTracker::get_tracking_status() const {
	return tracking_state;
}

bool VisionOSXRHandTracker::is_initialized() const {
	return initialized;
}

bool VisionOSXRHandTracker::initialize() {
	print_verbose("VisionOSXRHandTracker.initialize()");

	if (initialized) {
		ERR_PRINT("VisionOSXRHandTracker already initialized");
		return true;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, false);

	ERR_FAIL_NULL_V_MSG(xr_interface, false, "VisionOSXRHandTracker: xr_interface not set.");

	// Ensure the shared ARKit session exists (idempotent), so this tracker can be
	// initialized standalone from GDScript without the compositor services renderer.
	xr_interface->ensure_session();

	// Hand tracking provider (registered with the shared ARKit session)
	ar_hand_tracking_configuration_t hand_tracking_configuration = ar_hand_tracking_configuration_create();
	hand_tracking_provider = ar_hand_tracking_provider_create(hand_tracking_configuration);
	xr_interface->add_data_provider(hand_tracking_provider);

	// Hand tracker initialization
	left_hand_tracker.instantiate();
	left_hand_tracker->set_tracker_hand(XRPositionalTracker::TRACKER_HAND_LEFT);
	left_hand_tracker->set_tracker_name("/user/hand_tracker/left");
	XRServer::get_singleton()->add_tracker(left_hand_tracker);

	right_hand_tracker.instantiate();
	right_hand_tracker->set_tracker_hand(XRPositionalTracker::TRACKER_HAND_RIGHT);
	right_hand_tracker->set_tracker_name("/user/hand_tracker/right");
	XRServer::get_singleton()->add_tracker(right_hand_tracker);

	left_hand_anchor = ar_hand_anchor_create();
	right_hand_anchor = ar_hand_anchor_create();

	initialized = true;
	return initialized;
}

void VisionOSXRHandTracker::uninitialize() {
	if (!initialized) {
		return;
	}

	// Remove our hand tracking provider from the shared session
	if (hand_tracking_provider != nullptr && xr_interface != nullptr) {
		xr_interface->remove_data_provider(hand_tracking_provider);
		hand_tracking_provider = nullptr;
	}

	XRServer *xr_server = XRServer::get_singleton();
	if (xr_server != nullptr) {
		if (left_hand_tracker.is_valid()) {
			xr_server->remove_tracker(left_hand_tracker);
			left_hand_tracker.unref();
		}
		if (right_hand_tracker.is_valid()) {
			xr_server->remove_tracker(right_hand_tracker);
			right_hand_tracker.unref();
		}
		initialized = false;
	}
}

Dictionary VisionOSXRHandTracker::get_system_info() {
	Dictionary dict;

	dict[SNAME("XRRuntimeName")] = String("Godot visionOS Hand Tracker");
	dict[SNAME("XRRuntimeVersion")] = String("1.0");

	return dict;
}

Transform3D VisionOSXRHandTracker::get_camera_transform() {
	return Transform3D();
}

Transform3D VisionOSXRHandTracker::get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform, RID p_render_target) {
	return Transform3D();
}

Projection VisionOSXRHandTracker::get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far, RID p_render_target) {
	return Projection();
}

Size2 VisionOSXRHandTracker::get_render_target_size(RID p_render_target) {
	return Size2();
}

void VisionOSXRHandTracker::reset_hand_tracker_data(Ref<XRHandTracker> hand_tracker) {
	hand_tracker->set_hand_tracking_source(XRHandTracker::HAND_TRACKING_SOURCE_UNKNOWN);
	hand_tracker->set_has_tracking_data(false);
	hand_tracker->invalidate_pose("default");
}

void VisionOSXRHandTracker::set_hand_tracker_data_from_arkit(Ref<XRHandTracker> hand_tracker, ar_hand_anchor_t hand_anchor) {
	simd_float4x4 origin_from_hand_anchor_simd = ar_hand_anchor_get_origin_from_anchor_transform(hand_anchor);

	ar_hand_skeleton_t hand_skeleton = ar_hand_anchor_get_hand_skeleton(hand_anchor);
	Transform3D origin_from_hand_anchor = MTL::simd_to_transform3D(origin_from_hand_anchor_simd);

	// Rotate from ARKit coordinates to Godot Humanoid coordinates
	Transform3D origin_from_hand_anchor_adjusted = origin_from_hand_anchor;
	ar_hand_chirality_t chirality = ar_hand_anchor_get_chirality(hand_anchor);
	bool isLeftHand = (chirality == ar_hand_chirality_left);
	real_t rotationAngle = (isLeftHand ? -1 : 1) * Math::PI * 0.5;
	const Quaternion rotationX(Vector3(1, 0, 0), rotationAngle);
	const Quaternion rotationY(Vector3(0, 1, 0), rotationAngle);
	const Quaternion hand_position_axis_adjustment = rotationX * rotationY;
	origin_from_hand_anchor_adjusted.basis = origin_from_hand_anchor_adjusted.basis * hand_position_axis_adjustment;
	hand_tracker->set_pose("default", origin_from_hand_anchor_adjusted, Vector3(), Vector3());

	// ARKit hand tracking doesn't have a palm joint, set it to hand anchor transform
	BitField<XRHandTracker::HandJointFlags> flags = {};
	flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_ORIENTATION_VALID);
	flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_POSITION_VALID);
	flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_ORIENTATION_TRACKED);
	flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_POSITION_TRACKED);
	hand_tracker->set_hand_joint_transform(XRHandTracker::HAND_JOINT_PALM, origin_from_hand_anchor_adjusted);
	hand_tracker->set_hand_joint_flags(XRHandTracker::HAND_JOINT_PALM, flags);

	// Set rest of joints
	const Quaternion rotationZ(Vector3(0, 0, 1), rotationAngle);
	const Quaternion joint_axis_adjustment = rotationX * rotationZ;
	ar_hand_skeleton_enumerate_joints(hand_skeleton, ^bool(ar_skeleton_joint_t joint) {
		uint64_t joint_index = ar_skeleton_joint_get_index(joint);
		XRHandTracker::HandJoint hand_joint = joint_from_arkit((ar_hand_skeleton_joint_name_t)joint_index);
		if (hand_joint == XRHandTracker::HAND_JOINT_MAX) {
			return true;
		}
		simd_float4x4 hand_anchor_from_joint_simd = ar_skeleton_joint_get_anchor_from_joint_transform(joint);
		Transform3D hand_anchor_from_joint = MTL::simd_to_transform3D(hand_anchor_from_joint_simd);
		Transform3D origin_from_joint = origin_from_hand_anchor * hand_anchor_from_joint;
		origin_from_joint.basis = origin_from_joint.basis * joint_axis_adjustment;
		hand_tracker->set_hand_joint_transform(hand_joint, origin_from_joint);
		hand_tracker->set_hand_joint_flags(hand_joint, flags);
		return true;
	});

	hand_tracker->set_hand_tracking_source(XRHandTracker::HAND_TRACKING_SOURCE_UNOBSTRUCTED);
	hand_tracker->set_has_tracking_data(true);
}

void VisionOSXRHandTracker::update_hand_trackers_from_arkit() {
	if (!initialized) {
		return;
	}
	// This can be used together with the visionOS XR interface, or on its own
	CFTimeInterval trackable_anchor_time = 0;
	if (xr_interface != nullptr && xr_interface->is_initialized()) {
		// If it's used with the visionOS XR interface, process() on that interface must be called before this
		// so the current_predicted_timing is obtained. XR interfaces run process() in alphabetical
		// order ("visionOS" < "visionOSHandTracker"), so this constraint is satisfied.
		cp_frame_timing_t frame_timing = xr_interface->get_current_timing();
		if (frame_timing != nullptr) {
			trackable_anchor_time = cp_time_to_cf_time_interval(cp_frame_timing_get_trackable_anchor_time(frame_timing));
		}
	} else {
		// If it's used standalone, we obtain the estimatedPresentationTime from the active UIScene
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

	if (trackable_anchor_time != 0) {
		ar_hand_anchor_query_status_t query_anchor_result =
				ar_hand_tracking_provider_query_anchors_at_timestamp(hand_tracking_provider,
						trackable_anchor_time,
						left_hand_anchor,
						right_hand_anchor);

		if (query_anchor_result != ar_hand_anchor_query_status_success) {
			tracking_state = XRInterface::XR_NOT_TRACKING;
			reset_hand_tracker_data(left_hand_tracker);
			reset_hand_tracker_data(right_hand_tracker);
			ERR_FAIL_MSG("cannot query hand anchors, result: " + itos(query_anchor_result));
		}
	} else {
		// If we failed to get a trackable_anchor_time, we just get the latest anchors.
		// Tracking will be less precise in this case
		bool result = ar_hand_tracking_provider_get_latest_anchors(hand_tracking_provider, left_hand_anchor, right_hand_anchor);
		if (!result) {
			tracking_state = XRInterface::XR_NOT_TRACKING;
			reset_hand_tracker_data(left_hand_tracker);
			reset_hand_tracker_data(right_hand_tracker);
			ERR_FAIL_MSG("cannot query latest anchors, probably the ARKit session is not running");
		}
	}

	tracking_state = XRInterface::XR_NORMAL_TRACKING;

	if (ar_hand_anchor_is_tracked(left_hand_anchor)) {
		set_hand_tracker_data_from_arkit(left_hand_tracker, left_hand_anchor);
	} else {
		reset_hand_tracker_data(left_hand_tracker);
	}

	if (ar_hand_anchor_is_tracked(right_hand_anchor)) {
		set_hand_tracker_data_from_arkit(right_hand_tracker, right_hand_anchor);
	} else {
		reset_hand_tracker_data(right_hand_tracker);
	}
}

void VisionOSXRHandTracker::process() {
	if (!initialized) {
		return;
	}
	update_hand_trackers_from_arkit();
}

Vector<RenderingServerTypes::BlitToScreen> VisionOSXRHandTracker::post_draw_viewport(RID p_render_target, const Rect2 &p_screen_rect) {
	_THREAD_SAFE_METHOD_
	// We're overriding the color and depth textures, no need for screen blits
	return Vector<RenderingServerTypes::BlitToScreen>();
}

#endif // VISIONOS_ENABLED
