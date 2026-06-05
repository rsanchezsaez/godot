/**************************************************************************/
/*  register_types.mm                                                     */
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

#include "register_types.h"

#include "visionos_xr_controller_tracker.h"
#include "visionos_xr_hand_tracker.h"
#include "visionos_xr_interface.h"

#include "core/object/class_db.h"

Ref<VisionOSXRInterface> visionos_xr;
Ref<VisionOSXRHandTracker> visionos_hand_tracker;
Ref<VisionOSXRControllerTracker> visionos_controller_tracker;

void initialize_visionos_xr_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	GDREGISTER_CLASS(VisionOSXRInterface);
	GDREGISTER_CLASS(VisionOSXRHandTracker);
	GDREGISTER_CLASS(VisionOSXRControllerTracker);

	if (XRServer::get_singleton()) {
		visionos_xr.instantiate();
		XRServer::get_singleton()->add_interface(visionos_xr);

		visionos_hand_tracker.instantiate();
		visionos_hand_tracker->set_xr_interface(visionos_xr.ptr());
		XRServer::get_singleton()->add_interface(visionos_hand_tracker);

		visionos_controller_tracker.instantiate();
		visionos_controller_tracker->set_xr_interface(visionos_xr.ptr());
		XRServer::get_singleton()->add_interface(visionos_controller_tracker);
	}
}

void uninitialize_visionos_xr_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	if (visionos_controller_tracker.is_valid()) {
		if (visionos_controller_tracker->is_initialized()) {
			visionos_controller_tracker->uninitialize();
		}
		if (XRServer::get_singleton()) {
			XRServer::get_singleton()->remove_interface(visionos_controller_tracker);
		}
		visionos_controller_tracker.unref();
	}

	if (visionos_hand_tracker.is_valid()) {
		if (visionos_hand_tracker->is_initialized()) {
			visionos_hand_tracker->uninitialize();
		}
		if (XRServer::get_singleton()) {
			XRServer::get_singleton()->remove_interface(visionos_hand_tracker);
		}
		visionos_hand_tracker.unref();
	}

	if (visionos_xr.is_valid()) {
		// uninitialize our interface if it is initialized
		if (visionos_xr->is_initialized()) {
			visionos_xr->uninitialize();
		}

		// Destroy the shared ARKit session after all interfaces are uninitialized
		visionos_xr->destroy_session();

		// unregister our interface from the XR server
		if (XRServer::get_singleton()) {
			XRServer::get_singleton()->remove_interface(visionos_xr);
		}

		// and release
		visionos_xr.unref();
	}
}

#endif // VISIONOS_ENABLED
