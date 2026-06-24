/**************************************************************************/
/*  visionos_xr_interface.mm                                              */
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

#include "visionos_xr_interface.h"

#include "visionos_simd_helpers.h"
#include "visionos_xr_controller_tracker.h"
#include "visionos_xr_hand_tracker.h"

#include "core/config/project_settings.h"
#include "core/input/input.h"
#include "core/object/callable_mp.h"
#include "core/object/class_db.h"
#include "core/os/os.h"
#include "core/os/thread.h"
#include "drivers/metal/metal3_objects.h"
#include "drivers/metal/rendering_context_driver_metal.h"
#include "drivers/metal/rendering_device_driver_metal.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_server.h"
#include "servers/rendering/rendering_server_globals.h"
#include "servers/rendering/rendering_server_types.h"

#include "platform/visionos/godot_app_delegate_service_visionos.h"
#include "platform/visionos/render_mode_visionos.h"

#import <ARKit/ARKit.h>
#import <CompositorServices/CompositorServices.h>
#import <os/log.h>
#import <os/signpost.h>

static os_log_t signpost_log = os_log_create("org.godotengine.godot.compositorservices", "rendering");
static os_signpost_id_t current_signpost_id;

const String VisionOSXRInterface::name = "visionOS";

RenderingServer *VisionOSXRInterface::rendering_server = nullptr;
ar_world_tracking_provider_t VisionOSXRInterface::world_tracking_provider = nullptr;

StringName VisionOSXRInterface::get_signal_name(SignalEnum p_signal) {
	switch (p_signal) {
		case VISIONOS_XR_SIGNAL_SESSION_STARTED:
			return SNAME("session_started");
			break;
		case VISIONOS_XR_SIGNAL_SESSION_PAUSED:
			return SNAME("session_paused");
			break;
		case VISIONOS_XR_SIGNAL_SESSION_RESUMED:
			return SNAME("session_resumed");
			break;
		case VISIONOS_XR_SIGNAL_SESSION_INVALIDATED:
			return SNAME("session_invalidated");
			break;
		case VISIONOS_XR_SIGNAL_POSE_RECENTERED:
			return SNAME("pose_recentered");
			break;
		default:
			return "";
			break;
	}
}

void VisionOSXRInterface::emit_signal_enum(SignalEnum p_signal) {
	emit_signal(get_signal_name(p_signal));
}

void VisionOSXRInterface::_bind_methods() {
	// Signals
	for (int i = 0; i < VISIONOS_XR_SIGNAL_MAX; i++) {
		ADD_SIGNAL(MethodInfo(get_signal_name(static_cast<SignalEnum>(i))));
	}

	ClassDB::bind_method(D_METHOD("get_current_render_quality"), &VisionOSXRInterface::get_current_render_quality);
	ClassDB::bind_method(D_METHOD("set_current_render_quality", "render_quality"), &VisionOSXRInterface::set_current_render_quality);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "current_render_quality"), "set_current_render_quality", "get_current_render_quality");

	BIND_ENUM_CONSTANT(IMMERSION_STYLE_FULL);
	BIND_ENUM_CONSTANT(IMMERSION_STYLE_MIXED);
	BIND_ENUM_CONSTANT(IMMERSION_STYLE_PROGRESSIVE);
	ClassDB::bind_method(D_METHOD("get_immersion_style"), &VisionOSXRInterface::get_immersion_style);
	ClassDB::bind_method(D_METHOD("set_immersion_style", "immersion_style"), &VisionOSXRInterface::set_immersion_style);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "immersion_style", PROPERTY_HINT_ENUM, "Full,Mixed,Progressive"), "set_immersion_style", "get_immersion_style");

	BIND_ENUM_CONSTANT(VISIBILITY_AUTOMATIC);
	BIND_ENUM_CONSTANT(VISIBILITY_VISIBLE);
	BIND_ENUM_CONSTANT(VISIBILITY_HIDDEN);
	ClassDB::bind_method(D_METHOD("get_upper_limb_visibility"), &VisionOSXRInterface::get_upper_limb_visibility);
	ClassDB::bind_method(D_METHOD("set_upper_limb_visibility", "upper_limb_visibility"), &VisionOSXRInterface::set_upper_limb_visibility);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "upper_limb_visibility", PROPERTY_HINT_ENUM, "Automatic,Visible,Hidden"), "set_upper_limb_visibility", "get_upper_limb_visibility");
}

VisionOSXRInterface::VisionOSXRInterface() {
}

VisionOSXRInterface::~VisionOSXRInterface() {
	if (is_initialized()) {
		uninitialize();
	};
}

// Shared ARKit session management

void VisionOSXRInterface::ensure_session() {
	os_unfair_lock_lock(&session_lock);
	if (ar_session == nullptr) {
		ar_session = ar_session_create();
	}
	os_unfair_lock_unlock(&session_lock);
}

void VisionOSXRInterface::destroy_session() {
	os_unfair_lock_lock(&session_lock);
	registered_data_providers.clear();
	ar_session = nullptr;
	os_unfair_lock_unlock(&session_lock);
}

ar_session_t VisionOSXRInterface::get_ar_session() const {
	return ar_session;
}

void VisionOSXRInterface::add_data_provider(ar_data_provider_t p_provider) {
	os_unfair_lock_lock(&session_lock);
	registered_data_providers.push_back((__bridge void *)p_provider);
	rerun_session();
	os_unfair_lock_unlock(&session_lock);
}

void VisionOSXRInterface::remove_data_provider(ar_data_provider_t p_provider) {
	os_unfair_lock_lock(&session_lock);
	int64_t index = registered_data_providers.find((__bridge void *)p_provider);
	if (index >= 0) {
		registered_data_providers.remove_at(index);
		rerun_session();
	}
	os_unfair_lock_unlock(&session_lock);
}

void VisionOSXRInterface::rerun_session() {
	// Must be called with session_lock held.
	ERR_FAIL_NULL(ar_session);
	ar_data_providers_t data_providers = ar_data_providers_create();
	for (int i = 0; i < registered_data_providers.size(); i++) {
		ar_data_providers_add_data_provider(data_providers, (__bridge ar_data_provider_t)registered_data_providers[i]);
	}
	ar_session_run(ar_session, data_providers);
}

StringName VisionOSXRInterface::get_name() const {
	return VisionOSXRInterface::name;
}

uint32_t VisionOSXRInterface::get_capabilities() const {
	return XRInterface::XR_VR + XRInterface::XR_AR + XRInterface::XR_STEREO;
}

XRInterface::TrackingStatus VisionOSXRInterface::get_tracking_status() const {
	return tracking_state;
}

bool VisionOSXRInterface::is_initialized() const {
	return initialized;
}

bool VisionOSXRInterface::initialize() {
	if (initialized) {
		ERR_PRINT("VisionOSXRInterface already initialized");
		return true;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, false);

	String driver_name = OS::get_singleton()->get_current_rendering_driver_name().to_lower();
	ERR_FAIL_COND_V_MSG(driver_name != "metal", false, "The visionOS XR interface requires the Metal rendering driver.");

	GDTRenderMode app_delegate_render_mode = GDTAppDelegateServiceVisionOS.renderMode;
	ERR_FAIL_COND_V_MSG(app_delegate_render_mode != GDTRenderModeCompositorServices, false, "The visionOS XR interface requires GDTRenderModeCompositorServices render mode.");

	layer_renderer = GDTAppDelegateServiceVisionOS.layerRenderer;
	layer_renderer_capabilities = GDTAppDelegateServiceVisionOS.layerRendererCapabilities;

	ERR_FAIL_NULL_V_MSG(layer_renderer, false, "GDTAppDelegateServiceVisionOS.layerRenderer not set");
	ERR_FAIL_NULL_V_MSG(layer_renderer_capabilities, false, "GDTAppDelegateServiceVisionOS.layerRendererCapabilities not set");

	// ARKit session initialization (idempotent; lets this interface be initialized
	// independently from GDScript without relying on the module registration order)
	ensure_session();
	ar_world_tracking_configuration_t world_tracking_configuration = ar_world_tracking_configuration_create();
	world_tracking_provider = ar_world_tracking_provider_create(world_tracking_configuration);
	current_device_anchor = ar_device_anchor_create();
	add_data_provider(world_tracking_provider);

	// Head tracker initialization
	head_tracker.instantiate();
	head_tracker->set_tracker_type(XRServer::TRACKER_HEAD);
	head_tracker->set_tracker_name("head");
	head_tracker->set_tracker_desc("Device head pose");
	xr_server->add_tracker(head_tracker);

	// RenderThread
	rendering_server = RenderingServer::get_singleton();
	ERR_FAIL_NULL_V(rendering_server, false);
	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::initialize));

	float minimum_supported_near_plane = cp_layer_renderer_capabilities_supported_minimum_near_plane_distance(layer_renderer_capabilities);
	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::set_minimum_supported_near_plane).bind(minimum_supported_near_plane));

	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::bootstrap_swap_chain));

	// Make this our primary interface
	xr_server->set_primary_interface(this);

	initialized = true;

	// Initialize the trackers that are enabled via project settings. They can also be
	// initialized independently from GDScript; initialize() guards against double-init.
	if (GLOBAL_GET("xr/visionos/enable_hand_tracking")) {
		Ref<VisionOSXRHandTracker> hand_tracker = VisionOSXRHandTracker::find_interface();
		if (hand_tracker.is_valid()) {
			hand_tracker->initialize();
		}
	}
	if (GLOBAL_GET("xr/visionos/enable_controller_tracking")) {
		Ref<VisionOSXRControllerTracker> controller_tracker = VisionOSXRControllerTracker::find_interface();
		if (controller_tracker.is_valid()) {
			controller_tracker->initialize();
		}
	}

	return initialized;
}

void VisionOSXRInterface::uninitialize() {
	if (!initialized) {
		return;
	}

	// Tear down the trackers (reverse of initialize order). Each tracker's uninitialize()
	// is a no-op if it was never initialized.
	Ref<VisionOSXRControllerTracker> controller_tracker = VisionOSXRControllerTracker::find_interface();
	if (controller_tracker.is_valid()) {
		controller_tracker->uninitialize();
	}
	Ref<VisionOSXRHandTracker> hand_tracker = VisionOSXRHandTracker::find_interface();
	if (hand_tracker.is_valid()) {
		hand_tracker->uninitialize();
	}

	// Remove our world tracking provider from the shared session
	if (world_tracking_provider != nullptr) {
		remove_data_provider(world_tracking_provider);
		world_tracking_provider = nullptr;
	}

	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::uninitialize));

	XRServer *xr_server = XRServer::get_singleton();
	if (xr_server != nullptr) {
		if (head_tracker.is_valid()) {
			xr_server->remove_tracker(head_tracker);
			head_tracker.unref();
		}

		if (xr_server->get_primary_interface() == this) {
			// no longer our primary interface
			xr_server->set_primary_interface(nullptr);
		}

		initialized = false;
	}
}

void VisionOSXRInterface::RenderThread::bootstrap_swap_chain() {
	ERR_NOT_ON_RENDER_THREAD;

	// Trigger the swap chain's first resize and render-pass creation by calling
	// screen_prepare_for_drawing. The actual resize happens inside this call
	// because needs_resize was set in SurfaceCompositorServices's constructor.
	// This must happen BEFORE any cp_frame_start_submission so that
	// _flush_and_stall_for_all_frames (triggered by the resize) doesn't stall
	// in the middle of a CompositorServices submission.
	RenderingDevice::get_singleton()->screen_prepare_for_drawing(DisplayServerEnums::MAIN_WINDOW_ID);

	// Run a full empty CompositorServices frame cycle to read the real
	// render target size from the first drawable and cache it. Without this,
	// the engine's first iterate() would find cached_render_target_size == 0
	// and allocate the viewport at 0x0, skipping rendering of that frame.
	// The drawable is cleared (via a no-op render pass) and presented so it
	// progresses through the CompositorServices lifecycle cleanly, and we wait
	// for GPU completion so the drawable is fully retired before returning.
	cp_layer_renderer_t layer_renderer = GDTAppDelegateServiceVisionOS.layerRenderer;
	ERR_FAIL_NULL_MSG(layer_renderer, "GDTAppDelegateServiceVisionOS.layerRenderer not set");

	cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
	ERR_FAIL_NULL_MSG(frame, "cp_layer_renderer_query_next_frame returned nil during bootstrap");

	cp_frame_start_update(frame);
	cp_frame_end_update(frame);
	cp_frame_start_submission(frame);

	cp_drawable_array_t drawables = cp_frame_query_drawables(frame);
	size_t drawable_count = cp_drawable_array_get_count(drawables);

	ERR_FAIL_COND_MSG(drawable_count == 0, "No drawables found during bootstrap");

	for (size_t i = 0; i < drawable_count; i++) {
		cp_drawable_t drawable = cp_drawable_array_get_drawable(drawables, i);
		cache_drawable_size(drawable, frame);
		present_drawable_empty(drawable, frame);
	}
	cp_frame_end_submission(frame);

	print_line("[VisionOSXRInterface] bootstrap_swap_chain() completed");
}

void VisionOSXRInterface::RenderThread::initialize() {
	ERR_NOT_ON_RENDER_THREAD;
	rendering_device = RenderingDevice::get_singleton();
	RenderingDeviceDriverMetal *rendering_device_driver_metal = static_cast<RenderingDeviceDriverMetal *>(rendering_device->get_device_driver());
	pixel_formats = &rendering_device_driver_metal->get_pixel_formats();

	current_device_anchor = ar_device_anchor_create();

	// HQR viewport configuration
	// Create a virtual camera for our HQR viewport (the camera parameters will be overwritten in get_projection_for_view())
	hqr_camera = rendering_server->camera_create();
	rendering_server->camera_set_perspective(hqr_camera, 75, 0.1f, 4000.0f);
	// Create a virtual HQR viewport
	capture_viewport = rendering_server->viewport_create();
	rendering_server->viewport_set_disable_2d(capture_viewport, true);
	rendering_server->viewport_set_use_xr(capture_viewport, true);
	rendering_server->viewport_set_use_hdr_2d(capture_viewport, true);
	rendering_server->viewport_set_vrs_mode(capture_viewport, RSE::VIEWPORT_VRS_XR);
	rendering_server->viewport_set_update_mode(capture_viewport, RSE::VIEWPORT_UPDATE_ALWAYS);
	rendering_server->viewport_attach_camera(capture_viewport, hqr_camera);
	// Will only become active during HQR
	rendering_server->viewport_set_active(capture_viewport, false);
	// The main viewport will be populated by pre_draw_viewport()
	builtin_viewport = RID();

	initialized = true;
}

void VisionOSXRInterface::RenderThread::uninitialize() {
	ERR_NOT_ON_RENDER_THREAD;

	if (current_color_texture_id != RID()) {
		rendering_device->texture_owner.free(current_color_texture_id);
		current_color_texture_id = RID();
	}
	if (current_depth_texture_id != RID()) {
		rendering_device->texture_owner.free(current_depth_texture_id);
		current_depth_texture_id = RID();
	}
	if (current_rasterization_rate_map_id != RID()) {
		rendering_device->texture_owner.free(current_rasterization_rate_map_id);
		current_rasterization_rate_map_id = RID();
	}
	if (capture_viewport.is_valid()) {
		rendering_server->viewport_set_active(capture_viewport, false);
		rendering_server->free_rid(capture_viewport);
		capture_viewport = RID();
	}

	if (hqr_camera.is_valid()) {
		rendering_server->free_rid(hqr_camera);
		hqr_camera = RID();
	}

	initialized = false;
}

void VisionOSXRInterface::update_layer_renderer(cp_layer_renderer_t p_layer_renderer, cp_layer_renderer_capabilities_t p_layer_renderer_capabilities) {
	layer_renderer = p_layer_renderer;
	layer_renderer_capabilities = p_layer_renderer_capabilities;

	float minimum_supported_near_plane = cp_layer_renderer_capabilities_supported_minimum_near_plane_distance(layer_renderer_capabilities);
	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::set_minimum_supported_near_plane).bind(minimum_supported_near_plane));
}

Dictionary VisionOSXRInterface::get_system_info() {
	Dictionary dict;

	dict[SNAME("XRRuntimeName")] = String("Godot visionOS XR interface");
	dict[SNAME("XRRuntimeVersion")] = String("1.0");

	return dict;
}

VisionOSXRInterface::VRSTextureFormat VisionOSXRInterface::get_vrs_texture_format() {
	return XR_VRS_TEXTURE_FORMAT_RASTERIZATION_RATE_MAP;
}

bool VisionOSXRInterface::supports_play_area_mode(XRInterface::PlayAreaMode p_mode) {
	return p_mode == XR_PLAY_AREA_ROOMSCALE;
}

XRInterface::PlayAreaMode VisionOSXRInterface::get_play_area_mode() const {
	return XR_PLAY_AREA_ROOMSCALE;
}

bool VisionOSXRInterface::set_play_area_mode(XRInterface::PlayAreaMode p_mode) {
	return p_mode == XR_PLAY_AREA_ROOMSCALE;
}

cp_frame_timing_t VisionOSXRInterface::get_current_timing() {
	return current_timing;
}

float VisionOSXRInterface::get_current_render_quality() {
	return cp_layer_renderer_get_render_quality(layer_renderer);
}

void VisionOSXRInterface::set_current_render_quality(float p_render_quality) {
	ERR_FAIL_COND_MSG(!GDTAppDelegateServiceVisionOS.isDynamicRenderQualityEnabled, "Attempting to set current render quality but Dynamic Render Quality has not been enabled in Project Settings.");
	float maxRenderQuality = GDTAppDelegateServiceVisionOS.maxRenderQuality;
	ERR_FAIL_COND_MSG(p_render_quality > GDTAppDelegateServiceVisionOS.maxRenderQuality, vformat("Attempting to set a current render quality higher than the Max Render Quality configured in Project Settings (%f).", maxRenderQuality));
	cp_layer_renderer_set_render_quality(layer_renderer, p_render_quality);
}

VisionOSXRInterface::ImmersionStyle VisionOSXRInterface::get_immersion_style() {
	switch (GDTAppDelegateServiceVisionOS.immersionStyle) {
		case GDTImmersionStyleFull:
			return IMMERSION_STYLE_FULL;
		case GDTImmersionStyleMixed:
			return IMMERSION_STYLE_MIXED;
		case GDTImmersionStyleProgressive:
			return IMMERSION_STYLE_PROGRESSIVE;
		default:
			return IMMERSION_STYLE_FULL;
	}
}

void VisionOSXRInterface::set_immersion_style(ImmersionStyle p_immersion_style) {
	switch (p_immersion_style) {
		case IMMERSION_STYLE_FULL:
			GDTAppDelegateServiceVisionOS.immersionStyle = GDTImmersionStyleFull;
			break;
		case IMMERSION_STYLE_MIXED:
			GDTAppDelegateServiceVisionOS.immersionStyle = GDTImmersionStyleMixed;
			break;
		case IMMERSION_STYLE_PROGRESSIVE:
			GDTAppDelegateServiceVisionOS.immersionStyle = GDTImmersionStyleProgressive;
			break;
	}
}

VisionOSXRInterface::Visibility VisionOSXRInterface::get_upper_limb_visibility() {
	switch (GDTAppDelegateServiceVisionOS.upperLimbVisibility) {
		case GDTVisibilityAutomatic:
			return VISIBILITY_AUTOMATIC;
		case GDTVisibilityVisible:
			return VISIBILITY_VISIBLE;
		case GDTVisibilityHidden:
			return VISIBILITY_HIDDEN;
		default:
			return VISIBILITY_AUTOMATIC;
	}
}

void VisionOSXRInterface::set_upper_limb_visibility(Visibility p_upper_limb_visibility) {
	switch (p_upper_limb_visibility) {
		case VISIBILITY_AUTOMATIC:
			GDTAppDelegateServiceVisionOS.upperLimbVisibility = GDTVisibilityAutomatic;
			break;
		case VISIBILITY_VISIBLE:
			GDTAppDelegateServiceVisionOS.upperLimbVisibility = GDTVisibilityVisible;
			break;
		case VISIBILITY_HIDDEN:
			GDTAppDelegateServiceVisionOS.upperLimbVisibility = GDTVisibilityHidden;
			break;
	}
}

void VisionOSXRInterface::set_head_pose_from_arkit() {
	ERR_FAIL_NULL_MSG(current_frame, "Current frame is nil, probably process() has not been called, using identity transform");

	current_timing = cp_frame_predict_timing(current_frame);
	CFTimeInterval presentation_time = cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(current_timing));
	ar_device_anchor_query_status_t query_anchor_result = ar_world_tracking_provider_query_device_anchor_at_timestamp(world_tracking_provider, presentation_time, current_device_anchor);

	if (query_anchor_result != ar_device_anchor_query_status_success) {
		tracking_state = XRInterface::XR_NOT_TRACKING;
		ERR_FAIL_MSG("Cannot query device anchor, result: " + itos(query_anchor_result));
	}

	simd_float4x4 origin_from_head_simd = ar_anchor_get_origin_from_anchor_transform(current_device_anchor);
	tracking_state = XRInterface::XR_NORMAL_TRACKING;

	if (head_tracker.is_valid()) {
		// Set our head position (in real space, reference frame and world scale is applied later)
		head_tracker->set_pose("default", MTL::simd_to_transform3D(origin_from_head_simd), Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_HIGH);
	}
}

void VisionOSXRInterface::process() {
	if (!initialized) {
		return;
	}

	if (cp_layer_renderer_get_state(layer_renderer) == cp_layer_renderer_state_paused) {
		return;
	}

	// Generate a different ID every frame
	current_signpost_id = os_signpost_id_generate(signpost_log);
	os_signpost_interval_begin(signpost_log, current_signpost_id, "process");

	current_frame = cp_layer_renderer_query_next_frame(layer_renderer);

	ERR_FAIL_NULL_MSG(current_frame, "Layer renderer unexpectedly returned a nil frame, probably the layer renderer has been invalidated and it hasn't been updated to a new one");

	// Set head pose before engine update, so scripts can access fresh head tracker data
	set_head_pose_from_arkit();

	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::set_current_frame).bind(reinterpret_cast<uint64_t>(current_frame)));
	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::start_frame_update));

	os_signpost_interval_end(signpost_log, current_signpost_id, "process");
}

Size2 VisionOSXRInterface::get_render_target_size(RID p_render_target) {
	if (p_render_target == RID()) {
		WARN_PRINT_ONCE("VisionOSXRInterface::get_render_target_size called with empty RID");
	}
	Size2 size = rt.get_render_target_size(p_render_target);
	return size;
}

void VisionOSXRInterface::RenderThread::set_minimum_supported_near_plane(float p_minimum_supported_near_plane) {
	ERR_NOT_ON_RENDER_THREAD;
	minimum_supported_near_plane = p_minimum_supported_near_plane;
}

void VisionOSXRInterface::RenderThread::set_current_frame(uint64_t p_current_frame) {
	ERR_NOT_ON_RENDER_THREAD;
	current_frame = reinterpret_cast<cp_frame_t>(p_current_frame);

	// Query anchor again from the render thread
	cp_frame_timing_t current_timing = cp_frame_predict_timing(current_frame);
	CFTimeInterval presentation_time = cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(current_timing));
	ar_device_anchor_query_status_t query_anchor_result = ar_world_tracking_provider_query_device_anchor_at_timestamp(world_tracking_provider, presentation_time, current_device_anchor);

	if (query_anchor_result != ar_device_anchor_query_status_success) {
		ERR_FAIL_MSG("Cannot query device anchor, result: " + itos(query_anchor_result));
	}

	simd_float4x4 origin_from_head_simd = ar_anchor_get_origin_from_anchor_transform(current_device_anchor);
	origin_from_head = MTL::simd_to_transform3D(origin_from_head_simd);

	// Bootstrap: on the first frame, cached sizes are (0,0) which means the viewport
	// will have zero size and pre_draw_viewport() will never be called.
	// Query drawables early to get initial sizes. On subsequent frames, drawables are
	// populated properly in pre_render() after cp_frame_start_submission().
	if (cached_builtin_render_target_width.get() == 0 || cached_builtin_render_target_height.get() == 0) {
		populate_drawables();
	}
}

void VisionOSXRInterface::RenderThread::cache_drawable_size(cp_drawable_t p_drawable, cp_frame_t p_frame) {
	cp_drawable_target target = cp_drawable_get_target(p_drawable);
	id<MTLTexture> color_texture = cp_drawable_get_color_texture(p_drawable, 0);
	uint32_t view_count = cp_frame_get_drawable_target_view_count(p_frame, target);

	if (target == cp_drawable_target_built_in) {
		cached_builtin_render_target_width.set(color_texture.width);
		cached_builtin_render_target_height.set(color_texture.height);
		cached_builtin_view_count.set(view_count);
	} else if (target == cp_drawable_target_capture) {
		cached_capture_render_target_width.set(color_texture.width);
		cached_capture_render_target_height.set(color_texture.height);
		cached_capture_view_count.set(view_count);
	}
}

// Adds a render context to the drawable, encodes a no-op render command encoder
// to satisfy cp_drawable_render_context_end_encoding (the encoder must attach the
// drawable's textures so the render pipeline state pixel formats match), and
// finally encodes the present.
//
// Ideally, we will move the no-op encoder into the renderer by overriding that
// last [commandEncoder end], potentially introducing an API_TRAIT here:
// https://github.com/godotengine/godot/blob/4f26d675b67be94a43078651ebad2abc969d081f/servers/rendering/rendering_device_driver.h#L803-L813
static void encode_drawable_no_op_and_present(cp_drawable_t p_drawable, cp_frame_t p_frame, id<MTLCommandBuffer> p_command_buffer) {
	cp_drawable_render_context_t drawable_render_context = cp_drawable_add_render_context(p_drawable, p_command_buffer);

	id<MTLTexture> color_texture = cp_drawable_get_color_texture(p_drawable, 0);
	id<MTLTexture> depth_texture = cp_drawable_get_depth_texture(p_drawable, 0);

	MTLRenderPassDescriptor *render_pass_descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
	render_pass_descriptor.colorAttachments[0].texture = color_texture;
	render_pass_descriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
	render_pass_descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
	render_pass_descriptor.depthAttachment.texture = depth_texture;
	render_pass_descriptor.depthAttachment.loadAction = MTLLoadActionLoad;
	render_pass_descriptor.depthAttachment.storeAction = MTLStoreActionStore;
	render_pass_descriptor.renderTargetArrayLength = cp_frame_get_drawable_target_view_count(p_frame, cp_drawable_get_target(p_drawable));
	size_t count = cp_drawable_get_rasterization_rate_map_count(p_drawable);
	if (count > 0) {
		id<MTLRasterizationRateMap> rasterization_rate_map = cp_drawable_get_rasterization_rate_map(p_drawable, 0);
		MTLSize logical_size = rasterization_rate_map.screenSize;
		render_pass_descriptor.rasterizationRateMap = rasterization_rate_map;
		render_pass_descriptor.renderTargetWidth = logical_size.width;
		render_pass_descriptor.renderTargetHeight = logical_size.height;
	}

	id<MTLRenderCommandEncoder> command_encoder = [p_command_buffer renderCommandEncoderWithDescriptor:render_pass_descriptor];

	cp_drawable_render_context_end_encoding(drawable_render_context, command_encoder);

	cp_drawable_encode_present(p_drawable, p_command_buffer);
}

void VisionOSXRInterface::RenderThread::present_drawable_empty(cp_drawable_t p_drawable, cp_frame_t p_frame) {
	id<MTLDevice> device = (__bridge id<MTLDevice>)RenderModeVisionOS::get_compositor_services_device();
	id<MTLCommandQueue> command_queue = [device newCommandQueue];
	id<MTLCommandBuffer> command_buffer = [command_queue commandBuffer];
	encode_drawable_no_op_and_present(p_drawable, p_frame, command_buffer);
	[command_buffer commit];
}

void VisionOSXRInterface::RenderThread::populate_drawables() {
	cp_drawable_array_t drawables = cp_frame_query_drawables(current_frame);
	size_t drawable_count = cp_drawable_array_get_count(drawables);

	builtin_drawable = nullptr;
	capture_drawable = nullptr;

	for (size_t i = 0; i < drawable_count; i++) {
		cp_drawable_t drawable = cp_drawable_array_get_drawable(drawables, i);
		cp_drawable_target target = cp_drawable_get_target(drawable);
		if (target == cp_drawable_target_built_in) {
			builtin_drawable = drawable;
		} else if (target == cp_drawable_target_capture) {
			capture_drawable = drawable;
		}
		cp_drawable_set_device_anchor(drawable, current_device_anchor);
		cache_drawable_size(drawable, current_frame);
	}

	ERR_FAIL_NULL_MSG(builtin_drawable, "Built-in drawable not found in frame drawables");

	if (!capture_drawable) {
		cached_capture_render_target_width.set(0);
		cached_capture_render_target_height.set(0);
		cached_capture_view_count.set(0);
	}
}

uint32_t VisionOSXRInterface::RenderThread::get_view_count(RID p_render_target) {
	if (p_render_target == RID()) {
		WARN_PRINT_ONCE("VisionOSXRInterface::RenderThread::get_view_count called with empty RID");
	}
	if (is_capture_render_target(p_render_target)) {
		uint32_t view_count = cached_capture_view_count.get();
		return view_count;
	}
	uint32_t view_count = cached_builtin_view_count.get();
	return view_count;
}

Transform3D VisionOSXRInterface::RenderThread::get_camera_transform() {
	Transform3D camera_transform;
	ERR_NOT_ON_RENDER_THREAD_V(camera_transform);

	if (!initialized) {
		return camera_transform;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, camera_transform);
	// scale our origin point of our transform
	float world_scale = xr_server->get_world_scale();
	origin_from_head.origin *= world_scale;
	camera_transform = origin_from_head;
	return camera_transform;
}

Transform3D VisionOSXRInterface::RenderThread::get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform, RID p_render_target) {
	Transform3D origin_from_eye;
	ERR_NOT_ON_RENDER_THREAD_V(origin_from_eye);
	if (p_render_target == RID()) {
		WARN_PRINT_ONCE("VisionOSXRInterface::RenderThread::get_transform_for_view called with empty RID");
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, origin_from_eye);
	if (initialized) {
		cp_drawable_t drawable = is_capture_render_target(p_render_target) ? capture_drawable : builtin_drawable;
		ERR_FAIL_COND_V(p_view > get_view_count(p_render_target), origin_from_eye);
		ERR_FAIL_NULL_V_MSG(drawable, origin_from_eye, "Drawable is nil, probably pre_render() has not been called, using identity transform");

		cp_view_t view = cp_drawable_get_view(drawable, p_view);
		simd_float4x4 head_from_eye_simd = cp_view_get_transform(view);
		Transform3D head_from_eye = MTL::simd_to_transform3D(head_from_eye_simd);

		origin_from_eye = origin_from_head * head_from_eye;

		// Scale origin point by XROrigin3D's World Scale attribute
		float world_scale = xr_server->get_world_scale();
		origin_from_eye.origin *= world_scale;
	} else {
		ERR_PRINT("vision_vr_interface not initialized, returning received camera transform");
		origin_from_eye = Transform3D();
	};
	Transform3D reference_frame = xr_server->get_reference_frame();
	return p_cam_transform * reference_frame * origin_from_eye;
}

Projection VisionOSXRInterface::RenderThread::get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far, RID p_render_target) {
	Projection eye_projection;
	ERR_NOT_ON_RENDER_THREAD_V(eye_projection);
	if (p_render_target == RID()) {
		WARN_PRINT_ONCE("VisionOSXRInterface::RenderThread::get_projection_for_view called with empty RID");
	}

	if (!initialized) {
		return eye_projection;
	}

	// Update camera parameters for HQR rendering
	rendering_server->camera_set_perspective(hqr_camera, 75, p_z_near, p_z_far);

	cp_drawable_t drawable = is_capture_render_target(p_render_target) ? capture_drawable : builtin_drawable;
	ERR_FAIL_COND_V(p_view > get_view_count(p_render_target), eye_projection);
	ERR_FAIL_NULL_V_MSG(drawable, eye_projection, "Drawable is nil, probably pre_render() has not been called");

	XRServer *xr_server = XRServer::get_singleton();
	float world_scale = xr_server->get_world_scale();

	double scaled_z_near = p_z_near / world_scale;

	ERR_FAIL_COND_V_MSG(scaled_z_near < minimum_supported_near_plane, eye_projection, "Your XRCamera3D Near value is lower than the minimum value supported by the visionOS platform. Make sure that Near divided by XROrigin's World Scale is higher or equal than the value returned by LayerRender.Capabilities.supportedMinimumNearPlaneDistance. This value is 0.1 for Apple Vision Pro.");

	simd_float2 depth_range = simd_make_float2(p_z_far, scaled_z_near);
	cp_drawable_set_depth_range(drawable, depth_range);
	simd_float4x4 eye_simd_projection = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_forward, p_view);
	eye_projection = MTL::simd_to_projection(eye_simd_projection);

	// Godot renderers work in the normalized [-1, 1] depth space, and they do a final z remap of the projection matrixes to the [0, 1] depth space in RenderSceneDataRD::update_ubo().
	// Compositor Services projection matrices are already in the [0, 1] depth space, so we need to apply the inverse z remap before passing them to the renderer.
	Projection normalized_depth_correction;
	normalized_depth_correction.set_depth_correction(false, false, true);

	// Correct depth by world_scale
	Projection reverse_z;
	real_t *m = &reverse_z.columns[0][0];
	m[10] = -1.0;
	m[14] = 1.0;

	Projection world_scale_correction;
	world_scale_correction.make_scale(Vector3(1, 1, world_scale));

	eye_projection = normalized_depth_correction.inverse() * reverse_z.inverse() * world_scale_correction * reverse_z * eye_projection;
	return eye_projection;
}

// The render region is the logical texture size. With foveated rendering, it's bigger than the
// physical texture size. This value is equivalent to rasterizationRateMap.screenSize.
Rect2i VisionOSXRInterface::RenderThread::get_render_region() {
	Rect2 viewport_rect;

	ERR_NOT_ON_RENDER_THREAD_V(viewport_rect);

	if (!initialized) {
		return viewport_rect;
	}

	ERR_FAIL_NULL_V_MSG(current_drawable, viewport_rect, "Current drawable is nil, probably pre_render() has not been called");

	// The viewport should be the same for both eyes, so only get it from the first view
	cp_view_t view = cp_drawable_get_view(current_drawable, 0);
	cp_view_texture_map_t view_texture_map = cp_view_get_view_texture_map(view);
	MTLViewport viewport = cp_view_texture_map_get_viewport(view_texture_map);
	viewport_rect = MTL::rect_from_mtl_viewport(viewport);
	return viewport_rect;
}

Size2 VisionOSXRInterface::RenderThread::get_render_target_size(RID p_render_target) {
	if (p_render_target == RID()) {
		WARN_PRINT_ONCE("VisionOSXRInterface::RenderThread::get_render_target_size called with empty RID");
	}
	if (is_capture_render_target(p_render_target)) {
		Size2 size = Size2(cached_capture_render_target_width.get(), cached_capture_render_target_height.get());
		return size;
	}
	Size2 size = Size2(cached_builtin_render_target_width.get(), cached_builtin_render_target_height.get());
	return size;
}

void VisionOSXRInterface::RenderThread::start_frame_update() {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}

	os_signpost_interval_begin(signpost_log, current_signpost_id, "frame_update");

	ERR_FAIL_NULL_MSG(current_frame, "Current frame is nil, probably process() has not been called");
	cp_frame_start_update(current_frame);
}

void VisionOSXRInterface::RenderThread::end_frame_update() {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}

	ERR_FAIL_NULL_MSG(current_frame, "Current frame is nil, probably process() has not been called");
	cp_frame_end_update(current_frame);

	os_signpost_interval_end(signpost_log, current_signpost_id, "frame_update");
}

void VisionOSXRInterface::RenderThread::pre_render() {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}

	ERR_FAIL_NULL_MSG(current_frame, "Current frame is nil, probably process() has not been called");

	end_frame_update();

	os_signpost_interval_begin(signpost_log, current_signpost_id, "pre_render");
	os_signpost_interval_begin(signpost_log, current_signpost_id, "pre_render_wait");

	cp_frame_timing_t timing;
	if (builtin_drawable) {
		timing = cp_drawable_get_frame_timing(builtin_drawable);
	} else {
		timing = cp_frame_predict_timing(current_frame);
	}
	cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));

	os_signpost_interval_end(signpost_log, current_signpost_id, "pre_render_wait");

	cp_frame_start_submission(current_frame);
	encode_present_called = false;

	// Populate drawables now that submission has started and drawables are valid.
	populate_drawables();

	if (capture_drawable) {
		if (!rendering_server->viewport_get_active(capture_viewport)) {
			RID scenario = rendering_server->viewport_get_scenario(builtin_viewport);
			if (scenario == RID()) {
				print_line("[VisionOSXRInterface] pre_render(): capture_drawable detected but builtin_viewport has no scenario yet, skipping enabling viewport");
			} else {
				print_line("[VisionOSXRInterface] pre_render(): capture_drawable detected, enabling viewport");
				rendering_server->viewport_set_scenario(capture_viewport, scenario);
				rendering_server->viewport_set_size(capture_viewport, cached_capture_render_target_width.get(), cached_capture_render_target_height.get(), cached_capture_view_count.get());
				rendering_server->viewport_set_active(capture_viewport, true);
			}
		}
	} else if (!capture_drawable) {
		rendering_server->viewport_set_active(capture_viewport, false);
	}

	os_signpost_interval_end(signpost_log, current_signpost_id, "pre_render");
}

bool VisionOSXRInterface::RenderThread::pre_draw_viewport(RID p_render_target) {
	ERR_NOT_ON_RENDER_THREAD_V(false);

	if (!initialized) {
		return false;
	}

	// If builtin_viewport has not been set yet, set it here
	if (builtin_viewport == RID() && rendering_server->viewport_get_render_target(capture_viewport) != p_render_target) {
		builtin_viewport = rendering_server->viewport_get_for_render_target(p_render_target);
	}

	if (rendering_server->viewport_get_render_target(builtin_viewport) == p_render_target) {
		current_drawable = builtin_drawable;
	} else if (rendering_server->viewport_get_render_target(capture_viewport) == p_render_target) {
		current_drawable = capture_drawable;
	}
	return true;
}

bool VisionOSXRInterface::RenderThread::is_capture_render_target(RID p_render_target) {
	if (p_render_target == RID()) {
		return false;
	}
	return capture_viewport != RID() && rendering_server->viewport_get_render_target(capture_viewport) == p_render_target;
}

Vector<RenderingServerTypes::BlitToScreen> VisionOSXRInterface::RenderThread::post_draw_viewport(RID p_render_target, const Rect2 &p_screen_rect) {
	ERR_NOT_ON_RENDER_THREAD_V(Vector<RenderingServerTypes::BlitToScreen>());

	if (!initialized) {
		return Vector<RenderingServerTypes ::BlitToScreen>();
	}

	if (rendering_server->viewport_get_render_target(builtin_viewport) == p_render_target) {
		current_drawable = builtin_drawable;
	} else if (rendering_server->viewport_get_render_target(capture_viewport) == p_render_target) {
		current_drawable = capture_drawable;
	}

	// We're overriding the color and depth textures, no need for screen blits, return empty BlitToScreen vector
	// However, we need to acquire the dummy frame buffer
	RD::get_singleton()->screen_prepare_for_drawing(DisplayServerEnums::MAIN_WINDOW_ID);
	return Vector<RenderingServerTypes::BlitToScreen>();
}

void VisionOSXRInterface::RenderThread::encode_present(MTL3::MDCommandBuffer *p_cmd_buffer) {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}
	ERR_FAIL_NULL_MSG(current_frame, "Current frame is nil, probably process() has not been called");

	id<MTLCommandBuffer> command_buffer = (__bridge id<MTLCommandBuffer>)p_cmd_buffer->get_command_buffer();

	cp_drawable_array_t drawables = cp_frame_query_drawables(current_frame);
	size_t drawable_count = cp_drawable_array_get_count(drawables);

	for (size_t i = 0; i < drawable_count; i++) {
		cp_drawable_t drawable = cp_drawable_array_get_drawable(drawables, i);

		encode_drawable_no_op_and_present(drawable, current_frame, command_buffer);
	}
	encode_present_called = true;
}

void VisionOSXRInterface::RenderThread::end_frame() {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}

	ERR_FAIL_NULL_MSG(current_frame, "Current frame is nil, probably process() has not been called");

	// CompositorServices requires that cp_drawable_encode_present is called for
	// every drawable before cp_frame_end_submission, otherwise it triggers:
	// "BUG IN CLIENT: called cp_frame_end_submission() before calling
	// cp_drawable_encode_present() on the drawable".
	// If the renderer didn't present (e.g. the frame was skipped), present all
	// drawables here with a clearing command buffer to keep the frame lifecycle
	// well-formed.
	if (!encode_present_called) {
		WARN_PRINT("VisionOSXRInterface::RenderThread::encode_present() has not been called for this frame, presenting empty drawables. Make sure your XR viewport is visible and it has an appropriate size.");
		cp_drawable_array_t drawables = cp_frame_query_drawables(current_frame);
		size_t drawable_count = cp_drawable_array_get_count(drawables);
		for (size_t i = 0; i < drawable_count; i++) {
			cp_drawable_t drawable = cp_drawable_array_get_drawable(drawables, i);
			present_drawable_empty(drawable, current_frame);
		}
	}

	cp_frame_end_submission(current_frame);
	builtin_drawable = nullptr;
	capture_drawable = nullptr;
	current_drawable = nullptr;
	current_frame = nullptr;
}

RID VisionOSXRInterface::RenderThread::get_color_texture() {
	ERR_NOT_ON_RENDER_THREAD_V(RID());

	if (!initialized) {
		return RID();
	}

	if (current_color_texture_id != RID()) {
		rendering_device->texture_owner.free(current_color_texture_id);
		current_color_texture_id = RID();
	}

	ERR_FAIL_NULL_V_MSG(current_drawable, RID(), "Current drawable is nil, probably pre_render() has not been called");

	id<MTLTexture> color_texture = cp_drawable_get_color_texture(current_drawable, 0);
	current_color_texture_id = rendering_device->texture_create_from_extension(
			MTL::texture_type_from_metal(color_texture.textureType),
			pixel_formats->getDataFormat(static_cast<MTL::PixelFormat>(color_texture.pixelFormat)),
			MTL::texture_samples_from_metal(color_texture.sampleCount),
			RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT,
			reinterpret_cast<uint64_t>(color_texture),
			color_texture.width,
			color_texture.height,
			color_texture.depth,
			color_texture.arrayLength,
			color_texture.mipmapLevelCount);

	return current_color_texture_id;
}

RID VisionOSXRInterface::RenderThread::get_depth_texture() {
	ERR_NOT_ON_RENDER_THREAD_V(RID());

	if (!initialized) {
		return RID();
	}

	if (current_depth_texture_id != RID()) {
		rendering_device->texture_owner.free(current_depth_texture_id);
		current_depth_texture_id = RID();
	}

	ERR_FAIL_NULL_V_MSG(current_drawable, RID(), "Current drawable is nil, probably pre_render() has not been called");
	id<MTLTexture> depth_texture = cp_drawable_get_depth_texture(current_drawable, 0);

	current_depth_texture_id = rendering_device->texture_create_from_extension(
			MTL::texture_type_from_metal(depth_texture.textureType),
			pixel_formats->getDataFormat(static_cast<MTL::PixelFormat>(depth_texture.pixelFormat)),
			MTL::texture_samples_from_metal(depth_texture.sampleCount),
			RD::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_DEPTH_RESOLVE_ATTACHMENT_BIT,
			reinterpret_cast<uint64_t>(depth_texture),
			depth_texture.width,
			depth_texture.height,
			depth_texture.depth,
			depth_texture.arrayLength,
			depth_texture.mipmapLevelCount);

	return current_depth_texture_id;
}

RID VisionOSXRInterface::RenderThread::get_vrs_texture() {
	ERR_NOT_ON_RENDER_THREAD_V(RID());

	if (!initialized) {
		return RID();
	}

	if (current_rasterization_rate_map_id != RID()) {
		rendering_device->texture_owner.free(current_rasterization_rate_map_id);
		current_rasterization_rate_map_id = RID();
	}

	ERR_FAIL_NULL_V_MSG(current_drawable, RID(), "Current drawable is nil, probably pre_render() has not been called");
	size_t count = cp_drawable_get_rasterization_rate_map_count(current_drawable);

	// This is expected when performing a HQ Recording, because the recording drawable is unfoveated
	if (count == 0) {
		return RID();
	}

	id<MTLRasterizationRateMap> rasterization_rate_map = cp_drawable_get_rasterization_rate_map(current_drawable, 0);
	MTLSize logical_size = rasterization_rate_map.screenSize;

	RD::Texture texture;
	texture.driver_id = RDD::TextureID((__bridge void *)rasterization_rate_map);
	texture.usage_flags = RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_VRS_ATTACHMENT_BIT;
	texture.width = logical_size.width;
	texture.height = logical_size.height;
	texture.layers = rasterization_rate_map.layerCount;
	// The following spoofed values are unused, but they are required
	// to pass RenderingDevice::_render_pass_create() validation
	texture.type = RDD::TEXTURE_TYPE_2D_ARRAY;
	texture.format = RDD::DATA_FORMAT_R8_UINT;
	texture.samples = RDD::TEXTURE_SAMPLES_1;
	texture.depth = 1;
	texture.mipmaps = 1;
	ERR_FAIL_COND_V(!texture.driver_id, RID());

	current_rasterization_rate_map = texture;
	current_rasterization_rate_map_id = rendering_device->texture_owner.make_rid(current_rasterization_rate_map);

	return current_rasterization_rate_map_id;
}

#endif // VISIONOS_ENABLED
