/**************************************************************************/
/*  export_plugin.cpp                                                     */
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

#include "export_plugin.h"

#include "logo_svg.gen.h"
#include "run_icon_svg.gen.h"

EditorExportPlatformIOS::EditorExportPlatformIOS() :
	EditorExportPlatformAppleEmbedded(_ios_logo_svg, _ios_run_icon_svg) {
}

EditorExportPlatformIOS::~EditorExportPlatformIOS() {
}

void EditorExportPlatformIOS::get_export_options(List<ExportOption> *r_options) const {
	EditorExportPlatformAppleEmbedded::get_export_options(r_options);

	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/targeted_device_family", PROPERTY_HINT_ENUM, "iPhone,iPad,iPhone & iPad"), 2));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/min_ios_version"), "14.0"));

	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "storyboard/image_scale_mode", PROPERTY_HINT_ENUM, "Same as Logo,Center,Scale to Fit,Scale to Fill,Scale"), 0));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "storyboard/custom_image@2x", PROPERTY_HINT_FILE, "*.png,*.jpg,*.jpeg"), ""));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "storyboard/custom_image@3x", PROPERTY_HINT_FILE, "*.png,*.jpg,*.jpeg"), ""));
	r_options->push_back(ExportOption(PropertyInfo(Variant::BOOL, "storyboard/use_custom_bg_color"), false));
	r_options->push_back(ExportOption(PropertyInfo(Variant::COLOR, "storyboard/custom_bg_color"), Color()));
}

bool EditorExportPlatformIOS::has_valid_export_configuration(const Ref<EditorExportPreset> &p_preset, String &r_error, bool &r_missing_templates, bool p_debug) const {
	bool valid = EditorExportPlatformAppleEmbedded::has_valid_export_configuration(p_preset, r_error, r_missing_templates, p_debug);

	String err;
	String rendering_method = get_project_setting(p_preset, "rendering/renderer/rendering_method.mobile");
	String rendering_driver = get_project_setting(p_preset, "rendering/rendering_device/driver." + get_platform_name());
	if ((rendering_method == "forward_plus" || rendering_method == "mobile") && rendering_driver == "metal") {
		float version = p_preset->get("application/min_ios_version").operator String().to_float();
		if (version < 14.0) {
			err += TTR("Metal renderer require iOS 14+.") + "\n";
		}
	}

	if (!err.is_empty()) {
		if (!r_error.is_empty()) {
			r_error += err;
		} else {
			r_error = err;
		}
	}

	return valid;
}

HashMap<String, Variant> EditorExportPlatformIOS::get_custom_project_settings(const Ref<EditorExportPreset> &p_preset) const {
	HashMap<String, Variant> settings;

	int image_scale_mode = p_preset->get("storyboard/image_scale_mode");
	String value;

	switch (image_scale_mode) {
		case 0: {
			String logo_path = get_project_setting(p_preset, "application/boot_splash/image");
			bool is_on = get_project_setting(p_preset, "application/boot_splash/fullsize");
			// If custom logo is not specified, Godot does not scale default one, so we should do the same.
			value = (is_on && logo_path.length() > 0) ? "scaleAspectFit" : "center";
		} break;
		default: {
			value = storyboard_image_scale_mode[image_scale_mode - 1];
		}
	}
	settings["ios/launch_screen_image_mode"] = value;
	return settings;
}

Error EditorExportPlatformIOS::_export_loading_screen_file(const Ref<EditorExportPreset> &p_preset, const String &p_dest_dir) {
	const String custom_launch_image_2x = p_preset->get("storyboard/custom_image@2x");
	const String custom_launch_image_3x = p_preset->get("storyboard/custom_image@3x");

	if (custom_launch_image_2x.length() > 0 && custom_launch_image_3x.length() > 0) {
		String image_path = p_dest_dir.path_join("splash@2x.png");
		Error err = OK;
		Ref<Image> image = _load_icon_or_splash_image(custom_launch_image_2x, &err);

		if (err != OK || image.is_null() || image->is_empty()) {
			return err;
		}

		if (image->save_png(image_path) != OK) {
			return ERR_FILE_CANT_WRITE;
		}

		image_path = p_dest_dir.path_join("splash@3x.png");
		image = _load_icon_or_splash_image(custom_launch_image_3x, &err);

		if (err != OK || image.is_null() || image->is_empty()) {
			return err;
		}

		if (image->save_png(image_path) != OK) {
			return ERR_FILE_CANT_WRITE;
		}
	} else {
		Error err = OK;
		Ref<Image> splash;

		const String splash_path = get_project_setting(p_preset, "application/boot_splash/image");

		if (!splash_path.is_empty()) {
			splash = _load_icon_or_splash_image(splash_path, &err);
		}

		if (err != OK || splash.is_null() || splash->is_empty()) {
			splash.instantiate(boot_splash_png);
		}

		// Using same image for both @2x and @3x
		// because Godot's own boot logo uses single image for all resolutions.
		// Also not using @1x image, because devices using this image variant
		// are not supported by iOS 9, which is minimal target.
		const String splash_png_path_2x = p_dest_dir.path_join("splash@2x.png");
		const String splash_png_path_3x = p_dest_dir.path_join("splash@3x.png");

		if (splash->save_png(splash_png_path_2x) != OK) {
			return ERR_FILE_CANT_WRITE;
		}

		if (splash->save_png(splash_png_path_3x) != OK) {
			return ERR_FILE_CANT_WRITE;
		}
	}

	return OK;
}
