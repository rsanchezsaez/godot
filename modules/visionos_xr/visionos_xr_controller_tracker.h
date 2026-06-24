/**************************************************************************/
/*  visionos_xr_controller_tracker.h                                      */
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

#include "core/templates/local_vector.h"
#include "core/variant/variant.h"
#ifdef VISIONOS_ENABLED

#include "servers/xr/xr_controller_tracker.h"
#include "servers/xr/xr_interface.h"

#import <ARKit/ARKit.h>

@class GCController;
@class CHHapticEngine;

class VisionOSXRInterface;

class VisionOSXRControllerTracker : public XRInterface {
	GDCLASS(VisionOSXRControllerTracker, XRInterface);

private:
	// Core state
	bool initialized = false;
	XRInterface::TrackingStatus tracking_state;

	VisionOSXRInterface *xr_interface = nullptr;

	// ARKit state
	ar_accessory_tracking_provider_t controller_tracking_provider = nullptr;
	ar_accessories_t _accessories_to_add;
	ar_accessory_anchor_t left_controller_anchor;
	ar_accessory_anchor_t right_controller_anchor;

	// Lock for provider and accessories and controller state
	os_unfair_lock _accessory_lock;

	// Controller state
	Ref<XRControllerTracker> left_controller_tracker;
	Ref<XRControllerTracker> right_controller_tracker;
	GCController *left_gc_controller = nullptr;
	GCController *right_gc_controller = nullptr;
	CHHapticEngine *left_haptic_engine = nullptr;
	CHHapticEngine *right_haptic_engine = nullptr;

	// Notification observers
	id controller_observer = nullptr;
	id controller_disconnect_observer = nullptr;

	// Additional tracking correction
	Transform3D tracking_correction;

	struct Event {
		Ref<XRControllerTracker> controller_tracker;
		const char *action_name;
		Variant value;
	};

	/// Buffering events to avoid re-entering the same lock (shared between events and haptics)
	using Events = LocalVector<Event>;

	void update_controller_trackers_from_arkit();
	void update_controller_from_anchor(Ref<XRControllerTracker> controller_tracker, ar_accessory_anchor_t controller_anchor, GCController *gc_controller,
			bool is_left_hand, Events &);
	void setup_controller_notifications();
	void handle_controller_disconnect(GCController *controller);
	void cleanup_controller_notifications();
	void init_for_controller(GCController *controller);
	void run_provider();
	void run_provider_locked();

	struct Helpers;
	friend Helpers;

protected:
	static void _bind_methods();

public:
	static StringName name() { return "visionOSControllerTracker"; }
	static Ref<VisionOSXRControllerTracker> find_interface() {
		return XRServer::get_singleton()->find_interface(name());
	}

	VisionOSXRControllerTracker();
	~VisionOSXRControllerTracker();

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
	virtual void trigger_haptic_pulse(const String &p_action_name, const StringName &p_tracker_name, double p_frequency, double p_amplitude, double p_duration_sec, double p_delay_sec = 0) override;

	void set_tracking_correction(const Transform3D &p_correction);
};

#endif
