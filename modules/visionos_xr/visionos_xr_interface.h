/**************************************************************************/
/*  visionos_xr_interface.h                                               */
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

#include "core/templates/safe_refcount.h"
#include "drivers/metal/metal_objects_shared.h"
#include "drivers/metal/rendering_context_driver_metal.h"
#include "drivers/metal/rendering_device_driver_metal.h"
#include "servers/rendering/renderer_compositor.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_server.h"
#include "servers/xr/xr_interface.h"
#include "servers/xr/xr_positional_tracker.h"

#ifdef __OBJC__
// When compiling as Objective-C++, include the actual headers
#import <ARKit/ARKit.h>
#import <CompositorServices/CompositorServices.h>
#else
// When compiling as C++, use forward declarations for ARKit and CompositorServices types (opaque pointers)
typedef struct ar_world_tracking_provider *ar_world_tracking_provider_t;
typedef struct ar_data_provider *ar_data_provider_t;
typedef struct cp_layer_renderer *cp_layer_renderer_t;
typedef struct cp_layer_renderer_capabilities *cp_layer_renderer_capabilities_t;
typedef struct ar_session *ar_session_t;
typedef struct ar_device_anchor *ar_device_anchor_t;
typedef struct cp_frame *cp_frame_t;
typedef struct cp_drawable *cp_drawable_t;
typedef struct cp_frame_timing *cp_frame_timing_t;
#endif

#include <os/lock.h>

class RenderingDeviceDriverMetal;
class PixelFormats;

class VisionOSXRInterface : public XRInterface {
	GDCLASS(VisionOSXRInterface, XRInterface);

public:
	enum SignalEnum {
		VISIONOS_XR_SIGNAL_SESSION_STARTED,
		VISIONOS_XR_SIGNAL_SESSION_PAUSED,
		VISIONOS_XR_SIGNAL_SESSION_RESUMED,
		VISIONOS_XR_SIGNAL_SESSION_INVALIDATED,
		VISIONOS_XR_SIGNAL_POSE_RECENTERED,
		VISIONOS_XR_SIGNAL_MAX,
	};

	enum ImmersionStyle {
		IMMERSION_STYLE_FULL,
		IMMERSION_STYLE_MIXED,
		IMMERSION_STYLE_PROGRESSIVE,
	};

	enum Visibility {
		VISIBILITY_AUTOMATIC,
		VISIBILITY_VISIBLE,
		VISIBILITY_HIDDEN,
	};

private:
	bool initialized = false;
	XRInterface::TrackingStatus tracking_state;

	static RenderingServer *rendering_server;
	static ar_world_tracking_provider_t world_tracking_provider;

	cp_layer_renderer_t layer_renderer = nullptr;
	cp_layer_renderer_capabilities_t layer_renderer_capabilities = nullptr;

	// Shared ARKit session (created lazily via ensure_session() from initialize(), used by trackers)
	ar_session_t ar_session = nullptr;
	// Stored as void* to avoid ARC issues with ObjC pointers in Godot's Vector<> template
	Vector<void *> registered_data_providers;
	os_unfair_lock session_lock = OS_UNFAIR_LOCK_INIT;
	void rerun_session();

	ar_device_anchor_t current_device_anchor = nullptr;
	cp_frame_t current_frame = nullptr;

	cp_frame_timing_t current_timing = nullptr;

	// Data and functions only accessible from the rendering thread
	class RenderThread : public Object {
	private:
		bool initialized = false;

		RenderingDevice *rendering_device = nullptr;
		PixelFormats *pixel_formats = nullptr;

		float minimum_supported_near_plane = 0;

		// RenderThread must query the device anchor again,
		// because ar_device_anchor_t objects cannot be safely shared between threads
		ar_device_anchor_t current_device_anchor = nullptr;
		Transform3D origin_from_head;

		cp_frame_t current_frame = nullptr;
		cp_drawable_t builtin_drawable = nullptr;
		cp_drawable_t capture_drawable = nullptr;
		cp_drawable_t current_drawable = nullptr; // Convenience pointer set in pre_draw_viewport(), points to builtin_drawable or capture_drawable
		bool encode_present_called = false;

		RID hqr_camera;
		RID capture_viewport;
		RID builtin_viewport;

		RD::Texture current_color_texture;
		RID current_color_texture_id;
		RD::Texture current_depth_texture;
		RID current_depth_texture_id;
		RD::Texture current_rasterization_rate_map;
		RID current_rasterization_rate_map_id;

		// Cached render target size and view count per drawable, set in set_current_frame()
		// on the render thread and read from the game thread via get_render_target_size()/get_view_count().
		SafeNumeric<uint32_t> cached_builtin_render_target_width{ 0 };
		SafeNumeric<uint32_t> cached_builtin_render_target_height{ 0 };
		SafeNumeric<uint32_t> cached_builtin_view_count{ 0 };

		SafeNumeric<uint32_t> cached_capture_render_target_width{ 0 };
		SafeNumeric<uint32_t> cached_capture_render_target_height{ 0 };
		SafeNumeric<uint32_t> cached_capture_view_count{ 0 };

		bool is_capture_render_target(RID p_render_target);
		void populate_drawables();
		void cache_drawable_size(cp_drawable_t p_drawable, cp_frame_t p_frame);
		void present_drawable_empty(cp_drawable_t p_drawable, cp_frame_t p_frame);

	public:
		void initialize();
		void uninitialize();
		void bootstrap_swap_chain();

		void set_minimum_supported_near_plane(float p_minimum_supported_near_plane);

		// p_current_frame is a cp_frame_t pointer casted to uint64_t
		// This is to support calling this method through rendering_server->call_on_render_thread()
		// which only supports variant parameters
		void set_current_frame(uint64_t p_current_frame);

		// Safe to be called from the game thread
		void start_frame_update();
		void end_frame_update();
		Size2 get_render_target_size(RID p_render_target);

		// Only safe to be called from the render thread
		uint32_t get_view_count(RID p_render_target);
		Transform3D get_camera_transform();
		Transform3D get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform, RID p_render_target);
		Projection get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far, RID p_render_target);
		Rect2i get_render_region();

		void pre_render();
		bool pre_draw_viewport(RID p_render_target);
		Vector<RenderingServerTypes::BlitToScreen> post_draw_viewport(RID p_render_target, const Rect2 &p_screen_rect);
		void encode_present(MTL3::MDCommandBuffer *p_cmd_buffer);
		void end_frame();

		RID get_color_texture();
		RID get_depth_texture();
		RID get_vrs_texture();
	} rt;

	// Head tracker
	Ref<XRPositionalTracker> head_tracker;

	static void _bind_methods();
	static const String name;
	static StringName get_signal_name(SignalEnum p_signal);

	void set_head_pose_from_arkit();

public:
	static Ref<VisionOSXRInterface> find_interface() {
		return XRServer::get_singleton()->find_interface(name);
	}

	VisionOSXRInterface();
	~VisionOSXRInterface();

	// Shared ARKit session management
	void ensure_session();
	void destroy_session();
	ar_session_t get_ar_session() const;
	void add_data_provider(ar_data_provider_t p_provider);
	void remove_data_provider(ar_data_provider_t p_provider);

	void emit_signal_enum(SignalEnum p_signal);

	virtual StringName get_name() const override;
	virtual uint32_t get_capabilities() const override;

	virtual TrackingStatus get_tracking_status() const override;

	virtual bool is_initialized() const override;
	virtual bool initialize() override;
	virtual void uninitialize() override;

	// The LayerRenderer and Capabilities are polled from the app delegate when initializing the VisionOSXRInterface,
	// but they need to be updated when the app backgrounds and foregrounds because they are recreated by visionOS
	void update_layer_renderer(cp_layer_renderer_t p_layer_renderer, cp_layer_renderer_capabilities_t p_layer_renderer_capabilities);

	virtual Dictionary get_system_info() override;
	virtual VRSTextureFormat get_vrs_texture_format() override;

	virtual bool supports_play_area_mode(XRInterface::PlayAreaMode p_mode) override;
	virtual XRInterface::PlayAreaMode get_play_area_mode() const override;
	virtual bool set_play_area_mode(XRInterface::PlayAreaMode p_mode) override;

	cp_frame_timing_t get_current_timing();

	float get_current_render_quality();
	void set_current_render_quality(float p_render_quality);

	ImmersionStyle get_immersion_style();
	void set_immersion_style(ImmersionStyle p_immersion_style);

	Visibility get_upper_limb_visibility();
	void set_upper_limb_visibility(Visibility p_upper_limb_visibility);

	// Methods called from the game thread
	virtual void process() override;
	virtual Size2 get_render_target_size(RID p_render_target) override;

	// Methods only called from the render thread
	virtual uint32_t get_view_count(RID p_render_target) override {
		return rt.get_view_count(p_render_target);
	}
	virtual Transform3D get_camera_transform() override {
		return rt.get_camera_transform();
	}
	virtual Transform3D get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform, RID p_render_target) override {
		if (p_render_target == RID()) {
			WARN_PRINT_ONCE("VisionOSXRInterface::get_transform_for_view called with empty RID");
		}
		return rt.get_transform_for_view(p_view, p_cam_transform, p_render_target);
	}
	virtual Projection get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far, RID p_render_target) override {
		if (p_render_target == RID()) {
			WARN_PRINT_ONCE("VisionOSXRInterface::get_projection_for_view called with empty RID");
		}
		return rt.get_projection_for_view(p_view, p_aspect, p_z_near, p_z_far, p_render_target);
	}
	virtual Rect2i get_render_region() override {
		return rt.get_render_region();
	}
	virtual void pre_render() override {
		rt.pre_render();
	}
	virtual bool pre_draw_viewport(RID p_render_target) override {
		return rt.pre_draw_viewport(p_render_target);
	}
	virtual Vector<RenderingServerTypes::BlitToScreen> post_draw_viewport(RID p_render_target, const Rect2 &p_screen_rect) override {
		return rt.post_draw_viewport(p_render_target, p_screen_rect);
	}
	void encode_present(MTL3::MDCommandBuffer *p_cmd_buffer) {
		rt.encode_present(p_cmd_buffer);
	}
	virtual void end_frame() override {
		rt.end_frame();
	}

	virtual RID get_color_texture() override {
		return rt.get_color_texture();
	}
	virtual RID get_depth_texture() override {
		return rt.get_depth_texture();
	}
	virtual RID get_vrs_texture() override {
		return rt.get_vrs_texture();
	}
};

VARIANT_ENUM_CAST(VisionOSXRInterface::ImmersionStyle);
VARIANT_ENUM_CAST(VisionOSXRInterface::Visibility);

#endif
