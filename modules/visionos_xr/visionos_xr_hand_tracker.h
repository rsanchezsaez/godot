/**************************************************************************/
/*  visionos_xr_hand_tracker.h                                            */
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

#pragma once

#ifdef VISIONOS_ENABLED

#include "drivers/metal/rendering_context_driver_metal.h"
#include "drivers/metal/rendering_device_driver_metal.h"
#include "servers/xr/xr_hand_tracker.h"
#include "servers/xr/xr_interface.h"
#include "servers/xr/xr_positional_tracker.h"
#include "servers/xr/xr_vrs.h"

#import <ARKit/ARKit.h>
#import <CompositorServices/CompositorServices.h>

class VisionOSXRInterface;

class VisionOSXRHandTracker : public XRInterface {
	GDCLASS(VisionOSXRHandTracker, XRInterface);

private:
	bool initialized = false;
	XRInterface::TrackingStatus tracking_state;
	ar_hand_tracking_provider_t hand_tracking_provider = nullptr;

	VisionOSXRInterface *xr_interface = nullptr;

	// Hand trackers
	Ref<XRHandTracker> left_hand_tracker;
	Ref<XRHandTracker> right_hand_tracker;
	ar_hand_anchor_t left_hand_anchor;
	ar_hand_anchor_t right_hand_anchor;

	void update_hand_trackers_from_arkit();
	void reset_hand_tracker_data(Ref<XRHandTracker> hand_tracker);
	void set_hand_tracker_data_from_arkit(Ref<XRHandTracker> hand_tracker, ar_hand_anchor_t hand_anchor);

public:
	static StringName name() { return "visionOSHandTracker"; }
	static Ref<VisionOSXRHandTracker> find_interface() {
		return XRServer::get_singleton()->find_interface(name());
	}

	VisionOSXRHandTracker();
	~VisionOSXRHandTracker();

	void set_xr_interface(VisionOSXRInterface *p_interface) { xr_interface = p_interface; }

	virtual StringName get_name() const override;
	virtual uint32_t get_capabilities() const override;

	virtual TrackingStatus get_tracking_status() const override;

	virtual bool is_initialized() const override;
	virtual bool initialize() override;
	virtual void uninitialize() override;
	virtual Dictionary get_system_info() override;

	virtual Size2 get_render_target_size(RID p_render_target) override;
	virtual uint32_t get_view_count(RID p_render_target) override;

	virtual Transform3D get_camera_transform() override;
	virtual Transform3D get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform, RID p_render_target) override;
	virtual Projection get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far, RID p_render_target) override;

	virtual void process() override;
	virtual Vector<RenderingServerTypes::BlitToScreen> post_draw_viewport(RID p_render_target, const Rect2 &p_screen_rect) override;

	_FORCE_INLINE_ static XRHandTracker::HandJoint joint_from_arkit(ar_hand_skeleton_joint_name_t joint_name) {
		switch (joint_name) {
			case ar_hand_skeleton_joint_name_wrist:
				return XRHandTracker::HAND_JOINT_WRIST;
			case ar_hand_skeleton_joint_name_thumb_knuckle:
				return XRHandTracker::HAND_JOINT_THUMB_METACARPAL;
			case ar_hand_skeleton_joint_name_thumb_intermediate_base:
				return XRHandTracker::HAND_JOINT_THUMB_PHALANX_PROXIMAL;
			case ar_hand_skeleton_joint_name_thumb_intermediate_tip:
				return XRHandTracker::HAND_JOINT_THUMB_PHALANX_DISTAL;
			case ar_hand_skeleton_joint_name_thumb_tip:
				return XRHandTracker::HAND_JOINT_THUMB_TIP;
			case ar_hand_skeleton_joint_name_index_finger_metacarpal:
				return XRHandTracker::HAND_JOINT_INDEX_FINGER_METACARPAL;
			case ar_hand_skeleton_joint_name_index_finger_knuckle:
				return XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL;
			case ar_hand_skeleton_joint_name_index_finger_intermediate_base:
				return XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE;
			case ar_hand_skeleton_joint_name_index_finger_intermediate_tip:
				return XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL;
			case ar_hand_skeleton_joint_name_index_finger_tip:
				return XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP;
			case ar_hand_skeleton_joint_name_middle_finger_metacarpal:
				return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_METACARPAL;
			case ar_hand_skeleton_joint_name_middle_finger_knuckle:
				return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL;
			case ar_hand_skeleton_joint_name_middle_finger_intermediate_base:
				return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE;
			case ar_hand_skeleton_joint_name_middle_finger_intermediate_tip:
				return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL;
			case ar_hand_skeleton_joint_name_middle_finger_tip:
				return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_TIP;
			case ar_hand_skeleton_joint_name_ring_finger_metacarpal:
				return XRHandTracker::HAND_JOINT_RING_FINGER_METACARPAL;
			case ar_hand_skeleton_joint_name_ring_finger_knuckle:
				return XRHandTracker::HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL;
			case ar_hand_skeleton_joint_name_ring_finger_intermediate_base:
				return XRHandTracker::HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE;
			case ar_hand_skeleton_joint_name_ring_finger_intermediate_tip:
				return XRHandTracker::HAND_JOINT_RING_FINGER_PHALANX_DISTAL;
			case ar_hand_skeleton_joint_name_ring_finger_tip:
				return XRHandTracker::HAND_JOINT_RING_FINGER_TIP;
			case ar_hand_skeleton_joint_name_little_finger_metacarpal:
				return XRHandTracker::HAND_JOINT_PINKY_FINGER_METACARPAL;
			case ar_hand_skeleton_joint_name_little_finger_knuckle:
				return XRHandTracker::HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL;
			case ar_hand_skeleton_joint_name_little_finger_intermediate_base:
				return XRHandTracker::HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE;
			case ar_hand_skeleton_joint_name_little_finger_intermediate_tip:
				return XRHandTracker::HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL;
			case ar_hand_skeleton_joint_name_little_finger_tip:
				return XRHandTracker::HAND_JOINT_PINKY_FINGER_TIP;
			case ar_hand_skeleton_joint_name_forearm_wrist:
			case ar_hand_skeleton_joint_name_forearm_arm:
			default:
				// These don't have direct equivalents or are invalid
				return XRHandTracker::HAND_JOINT_MAX;
		}
	}
};

#endif
