@tool
class_name FigmaImporter
extends Control

var script_dir:String = get_script().get_path().get_base_dir()

@export_category("Figma JSON Import")
var is_json_proc:bool = false
## Select the json you exported from Figma.
@export_file("*.json") var document_json_file: set = json_load
## Process the JSON file to populate the Page list.
@export var process_json:bool = false: set = run_arrange
## Select the page from your Figma document you want to load.
@export var SelectPage : String : set = changePageSelect
## Select the Frame from the selected page you want to import. Currently the importer will display a list of top level frames.
@export_category("Figma ZIP Import")
## Point to the ZIP exported from Figma. Expected contents: *.json + images/ + fonts/.
@export_file("*.zip") var figma_zip_file: String
## One-shot trigger: extract ZIP, replace images/fonts, import frames, download fonts, cleanup.
@export var zip_extract_import: bool = false: set = run_zip_import
## Download fonts listed in JSON that are missing from the fonts folder (via Fontsource CDN).
@export var fetch_missing_fonts: bool = true
## After import: delete figma_download_fonts.bat, figma_export.json, and the ZIP.
@export var cleanup_temp_after_import: bool = true
@export var SelectFrame : String :
	set(value):
		SelectFrame = value
		notify_property_list_changed()
@export_group("Import Options")
## Select the folder to where you copied your fonts. Leaving this empy will result in using Godot's default font.
@export_dir var fonts_folder
## Select the folder to where you copied your images. Leaving this empty will result in images not being imported.
@export_dir var images_folder : 
	set(value):
		images_folder = value
		if images_folder == null || images_folder == "" || images_folder == " ":
			autoPlaceImages = false
		else: 
			autoPlaceImages = true
		notify_property_list_changed()
## Select or deselect if you want the importer to automatically import images.
@export var autoPlaceImages:bool = false
## Not required. Select the json file with the details of which instantiated scene should be used with specific frame ids.
@export_file("*.json") var component_json_dicionary: set = component_json_load
## This will instantiation child scenes from a matching id list of Figma components. This requires the id numbers match between Figma and Godot.
@export var compInstToScenes:bool = false
@export_group("Import Layouts")
## Renders the listed frames to the current node.
@export var importFrames:bool = false: set = renderFrameArray

var page_hints:String
var frame_hints:String
var current_depth:int = 0
var processed_json_dict:Dictionary
var is_comp_json:bool = false
var component_dictionary:Dictionary
var _zip_import_running: bool = false

func _validate_property(property : Dictionary) -> void:
	var zip_mode: bool = figma_zip_file != null and figma_zip_file != ""
	if property.name == &"SelectPage":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = page_hints
		if zip_mode:
			property.usage |= PROPERTY_USAGE_READ_ONLY
	if property.name == &"SelectFrame":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = frame_hints
	if property.name == &"document_json_file" and zip_mode:
		property.usage |= PROPERTY_USAGE_READ_ONLY
	if property.name == &"process_json" and zip_mode:
		property.usage |= PROPERTY_USAGE_READ_ONLY
	if property.name == "autoPlaceImages" and (images_folder == null || images_folder == ""):
		property.usage |= PROPERTY_USAGE_READ_ONLY
	if property.name == "compInstToScenes" and (component_json_dicionary == null || component_json_dicionary == ""):
		property.usage |= PROPERTY_USAGE_READ_ONLY
	if property.name == "importFrames" and (SelectFrame == null || SelectFrame == "" || SelectFrame == "Select Frame"):
		property.usage |= PROPERTY_USAGE_READ_ONLY

func changePageSelect(_stuff):
	SelectPage = _stuff
	if SelectPage != "Select Page" && SelectPage != "" && is_json_proc:
		var my_string = strip_to_id(SelectPage)
		if not processed_json_dict.has(my_string):
			notify_property_list_changed()
			return
		frame_hints = "Select Frame,"
		SelectFrame = "Select Frame"
		var page_children = processed_json_dict[my_string].get("children", [])
		if page_children == null:
			page_children = []
		for p_id in page_children:
			if processed_json_dict.has(p_id):
				frame_hints += str(processed_json_dict[p_id]["name"]) + " xIDx" + str(p_id) + "x,"
	notify_property_list_changed()

func component_json_load(_newVar):
	if Engine.is_editor_hint():
		component_json_dicionary = _newVar
		if component_json_dicionary != null:
			is_comp_json = true
			#Load the file.
			var data_file = FileAccess.open(_newVar, FileAccess.READ)
			#Parse the json file.
			var data_parsed = JSON.parse_string(data_file.get_as_text())
			component_dictionary = data_parsed
			compInstToScenes = true
		else:
			print("no json file")
			compInstToScenes = false
		notify_property_list_changed()

func json_load(_stuff):
	if Engine.is_editor_hint():
		print(script_dir)
		document_json_file = _stuff
		notify_property_list_changed()

func run_arrange(_newVar):
	if document_json_file != null:
		is_json_proc = true
		#Load the file.
		var data_file = FileAccess.open(document_json_file, FileAccess.READ)
		#Parse the json file.
		var data_parsed = JSON.parse_string(data_file.get_as_text())
		page_hints = "Select Page,"
		SelectPage = "Select Page"
		frame_hints = ""
		SelectFrame = ""
		processed_json_dict.clear()
		if data_parsed.has("type") and data_parsed["type"] == "FRAME":
			# Frame-only export: root adalah FRAME, tidak ada wrapper PAGE.
			page_hints += data_parsed["name"] + " xIDx" + data_parsed["id"] + "x,"
			cycle_children([data_parsed])
		elif data_parsed.has("children"):
			cycle_children(data_parsed["children"])
		else:
			print("Empty document")
		notify_property_list_changed()
	else:
		print("no json file")

func _wait_for_filesystem_idle() -> void:
	if not Engine.is_editor_hint():
		return
	var fs = EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	var timeout: float = 60.0
	var elapsed: float = 0.0
	while fs.is_scanning() and elapsed < timeout:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
	print("[FigmaImporter] Filesystem idle after %.1fs" % elapsed)

func _populate_frame_hints_from_all_pages() -> void:
	frame_hints = "Select Frame,"
	SelectFrame = ""
	if processed_json_dict.is_empty():
		notify_property_list_changed()
		return
	var seen: Dictionary = {}
	# Normal export: FRAME children of PAGE
	for id in processed_json_dict.keys():
		var node: Dictionary = processed_json_dict[id]
		if node["type"] == "PAGE" and node["children"] != null:
			for child_id in node["children"]:
				if seen.has(child_id):
					continue
				seen[child_id] = true
				var child: Dictionary = processed_json_dict.get(child_id, {})
				if child.is_empty():
					continue
				frame_hints += str(child["name"]) + " xIDx" + str(child_id) + "x,"
	# Frame-only export fallback: FRAME with no parent
	if seen.is_empty():
		for id in processed_json_dict.keys():
			var node: Dictionary = processed_json_dict[id]
			if node["type"] == "FRAME" and node["parent"] == null:
				seen[id] = true
				frame_hints += str(node["name"]) + " xIDx" + str(id) + "x,"
	# Last resort: any FRAME node
	if seen.is_empty():
		for id in processed_json_dict.keys():
			if processed_json_dict[id]["type"] == "FRAME":
				frame_hints += str(processed_json_dict[id]["name"]) + " xIDx" + str(id) + "x,"
	notify_property_list_changed()

func run_zip_import(val: bool) -> void:
	if not val or _zip_import_running:
		return
	if figma_zip_file == null or figma_zip_file == "" or not FileAccess.file_exists(figma_zip_file):
		push_error("[FigmaImporter] ZIP not found: " + str(figma_zip_file))
		return
	_zip_import_running = true

	var base_dir: String = figma_zip_file.get_base_dir()
	var temp_dir: String = base_dir + "/_figma_zip_tmp"
	var stable_json: String = base_dir + "/figma_export.json"

	if DirAccess.dir_exists_absolute(temp_dir):
		_delete_dir_recursive(temp_dir)
	DirAccess.make_dir_recursive_absolute(temp_dir)

	print("[FigmaImporter] Extracting ZIP: ", figma_zip_file)
	if _extract_zip(figma_zip_file, temp_dir) != OK:
		push_error("[FigmaImporter] ZIP extract failed.")
		_zip_import_running = false
		return

	var extracted_json: String = _find_first_by_ext(temp_dir, ".json")
	var extracted_images: String = _find_dir_named(temp_dir, "images")
	var extracted_fonts: String = _find_dir_named(temp_dir, "fonts")

	# --- Replace images ---
	if extracted_images != "":
		var target_images: String = images_folder if (images_folder != null and images_folder != "") else base_dir + "/images"
		print("[FigmaImporter] Replacing images: ", target_images)
		_delete_dir_recursive(target_images)
		DirAccess.make_dir_recursive_absolute(target_images)
		_copy_dir_recursive(extracted_images, target_images)
		images_folder = target_images
		autoPlaceImages = true
	else:
		print("[FigmaImporter] No 'images' folder inside ZIP — images folder unchanged.")

	# --- Replace fonts (OPTIONAL) ---
	if extracted_fonts != "":
		var target_fonts: String = fonts_folder if (fonts_folder != null and fonts_folder != "") else base_dir + "/fonts"
		print("[FigmaImporter] Replacing fonts: ", target_fonts)
		_delete_dir_recursive(target_fonts)
		DirAccess.make_dir_recursive_absolute(target_fonts)
		_copy_dir_recursive(extracted_fonts, target_fonts)
		fonts_folder = target_fonts
	else:
		print("[FigmaImporter] No 'fonts' folder inside ZIP — fonts folder unchanged (default font will be used where missing).")
		if fonts_folder == null or fonts_folder == "" or not DirAccess.dir_exists_absolute(fonts_folder):
			fonts_folder = ""

	# --- Prepare JSON ---
	if extracted_json == "":
		push_error("[FigmaImporter] No JSON inside ZIP.")
		_zip_import_running = false
		return

	var src = FileAccess.open(extracted_json, FileAccess.READ)
	if src == null:
		push_error("[FigmaImporter] Cannot read JSON from ZIP.")
		_zip_import_running = false
		return
	var content: String = src.get_as_text()
	src.close()
	var dst = FileAccess.open(stable_json, FileAccess.WRITE)
	if dst:
		dst.store_string(content)
		dst.close()
	document_json_file = stable_json

	# ==== Trigger filesystem scan FIRST so imports run in background ====
	EditorInterface.get_resource_filesystem().scan()
	print("[FigmaImporter] Filesystem scan triggered, waiting for import...")
	await _wait_for_filesystem_idle()

	# ==== Now parse JSON (safe, filesystem is idle) ====
	run_arrange(true)

	# ==== Populate SelectFrame directly, skip SelectPage ====
	_populate_frame_hints_from_all_pages()

	# ==== Best-effort font download (post-scan) ====
	if fetch_missing_fonts and fonts_folder != null and fonts_folder != "":
		await _fetch_missing_fonts()

	_delete_dir_recursive(temp_dir)

	if cleanup_temp_after_import:
		_cleanup_junk(base_dir)

	notify_property_list_changed()
	print("[FigmaImporter] ZIP import complete. Now choose a frame in 'SelectFrame' then enable 'importFrames'.")
	_zip_import_running = false

func _extract_zip(zip_path: String, dest_dir: String) -> int:
	var zr = ZIPReader.new()
	var err: int = zr.open(zip_path)
	if err != OK:
		return err
	for f in zr.get_files():
		var out_path: String = dest_dir + "/" + f
		if f.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(out_path)
			continue
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		var data: PackedByteArray = zr.read_file(f)
		var fa = FileAccess.open(out_path, FileAccess.WRITE)
		if fa:
			fa.store_buffer(data)
			fa.close()
	zr.close()
	return OK

func _find_first_by_ext(root: String, ext: String) -> String:
	var dir = DirAccess.open(root)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if fname.begins_with("."):
			fname = dir.get_next()
			continue
		var full: String = root + "/" + fname
		if dir.current_is_dir():
			var found: String = _find_first_by_ext(full, ext)
			if found != "":
				dir.list_dir_end()
				return found
		elif fname.to_lower().ends_with(ext.to_lower()):
			dir.list_dir_end()
			return full
		fname = dir.get_next()
	dir.list_dir_end()
	return ""

func _find_dir_named(root: String, name: String) -> String:
	var dir = DirAccess.open(root)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if fname.begins_with("."):
			fname = dir.get_next()
			continue
		var full: String = root + "/" + fname
		if dir.current_is_dir():
			if fname.to_lower() == name.to_lower():
				dir.list_dir_end()
				return full
			var found: String = _find_dir_named(full, name)
			if found != "":
				dir.list_dir_end()
				return found
		fname = dir.get_next()
	dir.list_dir_end()
	return ""

func _copy_dir_recursive(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var dir = DirAccess.open(src)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if fname.begins_with("."):
			fname = dir.get_next()
			continue
		var src_path: String = src + "/" + fname
		var dst_path: String = dst + "/" + fname
		if dir.current_is_dir():
			_copy_dir_recursive(src_path, dst_path)
		else:
			DirAccess.copy_absolute(src_path, dst_path)
		fname = dir.get_next()
	dir.list_dir_end()

func _delete_dir_recursive(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var dir = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if fname.begins_with("."):
			fname = dir.get_next()
			continue
		var full: String = path + "/" + fname
		if dir.current_is_dir():
			_delete_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		fname = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

func _cleanup_junk(base_dir: String) -> void:
	var junks: Array = [
		base_dir + "/figma_download_fonts.bat",
		base_dir + "/figma_export.json",
	]
	for j in junks:
		if j != "" and FileAccess.file_exists(j):
			DirAccess.remove_absolute(j)
			print("[FigmaImporter] Removed: ", j)
	# ZIP sengaja TIDAK dihapus — biarkan sebagai backup.

func _collect_required_fonts() -> Dictionary:
	var fonts: Dictionary = {}
	for id in processed_json_dict.keys():
		var node: Dictionary = processed_json_dict[id]
		if node["type"] != "TEXT":
			continue
		if node["fontName"] == null:
			continue
		var fam: String = str(node["fontName"].get("family", ""))
		var sty: String = str(node["fontName"].get("style", ""))
		if fam == "":
			continue
		var key: String = fam.replace(" ", "") + "_" + sty.replace(" ", "")
		fonts[key] = {"family": fam, "style": sty}
	return fonts

func _fetch_missing_fonts() -> void:
	if fonts_folder == null or fonts_folder == "":
		print("[FigmaImporter] fonts_folder empty — skipping font download, default font will be used.")
		return
	DirAccess.make_dir_recursive_absolute(fonts_folder)
	var needed: Dictionary = _collect_required_fonts()
	if needed.is_empty():
		print("[FigmaImporter] No text fonts referenced in JSON.")
		return
	for key in needed.keys():
		var fpath: String = fonts_folder + "/" + key + ".ttf"
		if FileAccess.file_exists(fpath):
			continue
		var fam: String = needed[key]["family"]
		var sty: String = needed[key]["style"]
		var url: String = _fontsource_url(fam, sty)
		print("[FigmaImporter] Downloading font: ", key, " ← ", url)
		var ok: bool = await _http_download(url, fpath)
		if ok:
			print("[FigmaImporter] Font saved: ", fpath)
		else:
			print("[FigmaImporter] Font download failed: ", key, " — falling back to Godot default font.")

func _fontsource_url(family: String, style: String) -> String:
	var font_id: String = family.to_lower().replace(" ", "-")
	var weight: int = 400
	var italic: String = "normal"
	var ls: String = style.to_lower()
	if "thin" in ls: weight = 100
	elif "extralight" in ls or "extra light" in ls: weight = 200
	elif "light" in ls: weight = 300
	elif "medium" in ls: weight = 500
	elif "semibold" in ls or "semi bold" in ls: weight = 600
	elif "extrabold" in ls or "extra bold" in ls: weight = 800
	elif "black" in ls: weight = 900
	elif "bold" in ls: weight = 700
	if "italic" in ls:
		italic = "italic"
	return "https://cdn.jsdelivr.net/fontsource/fonts/%s@latest/latin-%d-%s.ttf" % [font_id, weight, italic]

func _http_download(url: String, save_path: String) -> bool:
	var http := HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	var err: int = http.request(url)
	if err != OK:
		http.queue_free()
		return false
	var result: Array = await http.request_completed
	http.queue_free()
	if result[1] != 200:
		return false
	var fa = FileAccess.open(save_path, FileAccess.WRITE)
	if fa == null:
		return false
	fa.store_buffer(result[3])
	fa.close()
	return true

func cycle_children(what_to_process):
	if what_to_process.size() > 0:
		for new_item in what_to_process.size():
			var fig_id = test_key(what_to_process[new_item],"id")
			var fig_name = test_key(what_to_process[new_item],"name")
			var fig_children:Array
			var fig_comp_props:Dictionary
			var fig_comp_prop_defs:Dictionary
			var fig_master_comp:String
			if what_to_process[new_item]["type"] == "PAGE":
				page_hints += fig_name+" xIDx"+fig_id+"x,"
				notify_property_list_changed()
			elif what_to_process[new_item]["type"] == "COMPONENT":
				if what_to_process[new_item].has("componentPropertyDefinitions"):
					fig_comp_prop_defs = what_to_process[new_item]["componentPropertyDefinitions"]
			elif what_to_process[new_item]["type"] == "INSTANCE":
				fig_master_comp = test_key(test_key(what_to_process[new_item], "masterComponent"), "id")
				if what_to_process[new_item].has("componentProperties"):
					fig_comp_props = what_to_process[new_item]["componentProperties"]
			var with_child:bool = false
			if what_to_process[new_item].has("children"):
				with_child = true
				for new_child in what_to_process[new_item]["children"].size():
					fig_children.append(what_to_process[new_item]["children"][new_child]["id"])
			processed_json_dict[fig_id] = {
				"type" : test_key(what_to_process[new_item],"type"),
				"name" : fig_name,
				"parent": test_key(test_key(what_to_process[new_item], "parent"), "id"),
				"x" : test_key(what_to_process[new_item],"x"),
				"y" : test_key(what_to_process[new_item],"y"),
				"width" : test_key(what_to_process[new_item],"width"),
				"height" : test_key(what_to_process[new_item],"height"),
				"minWidth" : test_key(what_to_process[new_item],"minWidth"),
				"minHeight" : test_key(what_to_process[new_item],"minHeight"),
				"maxWidth" : test_key(what_to_process[new_item],"maxWidth"),
				"maxHeight" : test_key(what_to_process[new_item],"maxHeight"),
				"rotation" : test_key(what_to_process[new_item],"rotation"),
				"fills" : test_key(what_to_process[new_item],"fills"),
				"padding" : [test_key(what_to_process[new_item],"paddingTop"),test_key(what_to_process[new_item],"paddingRight"),test_key(what_to_process[new_item],"paddingBottom"),test_key(what_to_process[new_item],"paddingLeft")],
				"corner_radius" : [test_key(what_to_process[new_item],"topLeftRadius"),test_key(what_to_process[new_item],"topRightRadius"),test_key(what_to_process[new_item],"bottomRightRadius"),test_key(what_to_process[new_item],"bottomLeftRadius")],
				"border_weights" : [test_key(what_to_process[new_item],"strokeTopWeight"),test_key(what_to_process[new_item],"strokeRightWeight"),test_key(what_to_process[new_item],"strokeBottomWeight"),test_key(what_to_process[new_item],"strokeLeftWeight")],
				"border_color" : test_key(what_to_process[new_item],"strokes"),
				"stroke_weight" : test_key(what_to_process[new_item],"strokeWeight"),
				"layout_wrap" : test_key(what_to_process[new_item],"layoutWrap"),
				"layout_mode" : test_key(what_to_process[new_item],"layoutMode"),
				"layout_horiz_sizing" : test_key(what_to_process[new_item],"layoutSizingHorizontal"),
				"layout_vert_sizing" : test_key(what_to_process[new_item],"layoutSizingVertical"),
				"hLayout_Align": proc_hlayoutAlign(test_key(what_to_process[new_item],"primaryAxisAlignItems")),
				"vLayout_Align": proc_vlayoutAlign(test_key(what_to_process[new_item],"counterAxisAlignItems")),
				"clip_content" : test_key(what_to_process[new_item],"clipsContent"),
				"horizontalAnchor" : proc_halignments(test_key(what_to_process[new_item],"constraints")),
				"verticalAnchor" : proc_valignments(test_key(what_to_process[new_item],"constraints")),
				"children" : fig_children,
				"gap_spacing" : test_key(what_to_process[new_item],"itemSpacing"),
				"vertical_gap_spacing" : test_key(what_to_process[new_item],"counterAxisSpacing"),
				"master_comp" : fig_master_comp,
				"component_properties" : fig_comp_props,
				"component_property_defs" : fig_comp_prop_defs,
				"textAlignHorizontal": test_key(what_to_process[new_item],"textAlignHorizontal"),
				"textAlignVertical": test_key(what_to_process[new_item],"textAlignVertical"),
				"textTruncation": test_key(what_to_process[new_item],"textTruncation"),
				"characters": test_key(what_to_process[new_item],"characters"),
				"fontName": test_key(what_to_process[new_item],"fontName"),
				"fontWeight": test_key(what_to_process[new_item],"fontWeight"),
				"fontSize": test_key(what_to_process[new_item],"fontSize"),
				"fontStrokeWeight": test_key(what_to_process[new_item],"strokeWeight"),
				"relativeTransform": test_key(what_to_process[new_item],"relativeTransform")
			}
			if with_child:
				cycle_children(what_to_process[new_item]["children"])

func renderFrameArray(_stuff):
	var frame_id = strip_to_id(SelectFrame)
	renderFrameAndContents(frame_id,self,true)

func renderChildFrames(frame,parent):
	for object_id in processed_json_dict[frame]["children"]:
		renderFrameAndContents(object_id,parent,false)

func renderFrameAndContents(object_id,parent,position_override:bool):
	var the_type = processed_json_dict[object_id]["type"]
	if the_type == "TEXT":
		renderTextFrame(parent,object_id)
	elif the_type == "LINE":
		renderLine(parent,object_id)
	elif the_type == "INSTANCE" && compInstToScenes:
		place_component_inst(parent,object_id)
	else:
		var newFrame
		var isRectangle:bool = false
		if the_type == "RECTANGLE":
			isRectangle = true
		if isRectangle:
			newFrame = DesignerImagePanel.new()
		else:
			newFrame = DesignerFrame.new()
		
		# Nama node murni hanya menggunakan nama dari Figma yang sudah dibersihkan karakternya
		newFrame.name = make_safeName(processed_json_dict[object_id]["name"])
		
		parent.add_child(newFrame)
		newFrame.set_owner(get_tree().get_edited_scene_root())
		newFrame.use_solid_fill = false
		if !isRectangle:
			newFrame.scrollingMode = "None"
			var newControl = Control.new()
			newControl.name = "InnerContainer"
			newFrame.add_child(newControl)
			newFrame.inner_container = newControl.get_path()
			newFrame.get_node(newFrame.inner_container).set_owner(get_tree().get_edited_scene_root())
		newFrame.the_id = object_id
		newFrame.widthSizeMode = processed_json_dict[object_id]["layout_horiz_sizing"]
		newFrame.heightSizeMode = processed_json_dict[object_id]["layout_vert_sizing"]
		if processed_json_dict[object_id]["minWidth"] != null:
			newFrame.minSize.x = processed_json_dict[object_id]["minWidth"]
		else:
			newFrame.minSize.x = 0.0
		if processed_json_dict[object_id]["minHeight"] != null:
			newFrame.minSize.y = processed_json_dict[object_id]["minHeight"]
		else:
			newFrame.minSize.y = 0.0
		if processed_json_dict[object_id]["maxWidth"] != null:
			newFrame.maxSize.x = processed_json_dict[object_id]["maxWidth"]
		else:
			newFrame.maxSize.x = 100000.0
		if processed_json_dict[object_id]["maxHeight"] != null:
			newFrame.maxSize.y = processed_json_dict[object_id]["maxHeight"]
		else:
			newFrame.maxSize.y = 100000.0
		newFrame.set_deferred("size", Vector2(processed_json_dict[object_id]["width"],processed_json_dict[object_id]["height"]))
		if processed_json_dict[object_id]["layout_horiz_sizing"] == "FIXED" && processed_json_dict[object_id]["minWidth"] == null:
			newFrame.minSize.x = processed_json_dict[object_id]["width"]
		if processed_json_dict[object_id]["layout_vert_sizing"] == "FIXED" && processed_json_dict[object_id]["minHeight"] == null:
			newFrame.minSize.y = processed_json_dict[object_id]["height"]
		if position_override:
			newFrame.set_deferred("position", Vector2(0.0,0.0))
		else:
			newFrame.set_deferred("position", Vector2(processed_json_dict[object_id]["x"],processed_json_dict[object_id]["y"]))
		newFrame.set_deferred("rotation_degrees", processed_json_dict[object_id]["rotation"] * -1)
		if processed_json_dict[object_id]["relativeTransform"][0][0] < 0:
			newFrame.scale.y *= -1
		if processed_json_dict[object_id]["relativeTransform"][1][1] < 0:
			newFrame.scale.y *= -1
		newFrame.set_deferred("center_rotation", true)
		if !isRectangle:
			newFrame.padding = processed_json_dict[object_id]["padding"]
		newFrame.fill_color = Color(0.0,0.0,0.0,0.0)
		if the_type == "POLYGON" || the_type == "VECTOR" || the_type == "STAR":
			place_error_image(newFrame)
		elif processed_json_dict[object_id]["fills"] != null && processed_json_dict[object_id]["fills"] != []:
			process_colors(processed_json_dict[object_id]["fills"],newFrame)
		if processed_json_dict[object_id]["border_color"] != [] && processed_json_dict[object_id]["border_color"] != null:
			newFrame.border_color = Color(processed_json_dict[object_id]["border_color"][0]["color"]["r"],processed_json_dict[object_id]["border_color"][0]["color"]["g"],processed_json_dict[object_id]["border_color"][0]["color"]["b"])
			newFrame.border_weights = processed_json_dict[object_id]["border_weights"]
		newFrame.corner_radius = processed_json_dict[object_id]["corner_radius"]
		if !isRectangle:
			if processed_json_dict[object_id]["layout_wrap"] != null:
				newFrame.layoutWrap = processed_json_dict[object_id]["layout_wrap"]
				if processed_json_dict[object_id]["layout_wrap"] == "NO_WRAP":
					newFrame.layoutMode = processed_json_dict[object_id]["layout_mode"]
			if processed_json_dict[object_id]["gap_spacing"] != null:
				newFrame.spacing = processed_json_dict[object_id]["gap_spacing"]
			if processed_json_dict[object_id]["vertical_gap_spacing"] != null:
				newFrame.secondary_spacing = processed_json_dict[object_id]["vertical_gap_spacing"]
		if processed_json_dict[object_id]["clip_content"] != null:
			newFrame.clipFrameContents = processed_json_dict[object_id]["clip_content"]
		newFrame.set_deferred("horizontalAnchor", processed_json_dict[object_id]["horizontalAnchor"])
		newFrame.set_deferred("verticalAnchor", processed_json_dict[object_id]["verticalAnchor"])
		newFrame.set_deferred("hLayoutAlign", processed_json_dict[object_id]["hLayout_Align"])
		newFrame.set_deferred("vLayoutAlign", processed_json_dict[object_id]["vLayout_Align"])
		if !isRectangle:
			if processed_json_dict[object_id]["children"] != null && processed_json_dict[object_id]["children"] != []:
				renderChildFrames(object_id,newFrame.get_node(newFrame.inner_container))

func renderLine(parent,p_id):
	pass
	var newFrame = HSeparator.new()
	
	# Nama node line murni dari Figma
	newFrame.name = make_safeName(processed_json_dict[p_id]["name"])
	
	parent.add_child(newFrame)
	newFrame.set_owner(get_tree().get_edited_scene_root())
	newFrame.set_deferred("size", Vector2(processed_json_dict[p_id]["width"],processed_json_dict[p_id]["stroke_weight"]))
	if processed_json_dict[p_id]["layout_horiz_sizing"] == "FIXED" && processed_json_dict[p_id]["minWidth"] == null:
		newFrame.set_deferred("custom_minimum_size:x", processed_json_dict[p_id]["width"])
	if processed_json_dict[p_id]["layout_vert_sizing"] == "FIXED" && processed_json_dict[p_id]["minHeight"] == null:
		newFrame.set_deferred("custom_minimum_size:y", processed_json_dict[p_id]["height"])
	newFrame.set_deferred("position", Vector2(processed_json_dict[p_id]["x"],processed_json_dict[p_id]["y"]))
	newFrame.set_deferred("rotation_degrees", processed_json_dict[p_id]["rotation"] * -1)
	newFrame.set_deferred("center_rotation", true)
	var stylebox_line = StyleBoxLine.new()
	stylebox_line.set("color",Color(processed_json_dict[p_id]["border_color"][0]["color"]["r"],processed_json_dict[p_id]["border_color"][0]["color"]["g"],processed_json_dict[p_id]["border_color"][0]["color"]["b"]))
	stylebox_line.set("thickness", processed_json_dict[p_id]["stroke_weight"])
	stylebox_line.set("grow_begin", 0)
	stylebox_line.set("grow_end", 0)
	newFrame.add_theme_stylebox_override("separator", stylebox_line)
	newFrame.set_deferred("horizontalAnchor", processed_json_dict[p_id]["horizontalAnchor"])
	newFrame.set_deferred("verticalAnchor", processed_json_dict[p_id]["verticalAnchor"])
	newFrame.set_deferred("hLayoutAlign", processed_json_dict[p_id]["hLayout_Align"])
	newFrame.set_deferred("vLayoutAlign", processed_json_dict[p_id]["vLayout_Align"])

func renderTextFrame(parent,p_id):
	var newFrame = Label.new()
	var newLabelSettings = LabelSettings.new()
	newLabelSettings.line_spacing = 0
	if fonts_folder != null and fonts_folder != "":
		var dynamic_font = FontFile.new()
		var font_name = str(processed_json_dict[p_id]["fontName"]["family"]).replace(" ", "")
		var font_style = str(processed_json_dict[p_id]["fontName"]["style"]).replace(" ", "")
		var font_location:String = fonts_folder + "/" + font_name + "_" + font_style + ".ttf"
		if FileAccess.file_exists(font_location):
			newLabelSettings.font = load(font_location)
	set_anchor_horizontal_fup(processed_json_dict[p_id]["horizontalAnchor"],newFrame)
	set_anchor_vertical_fup(processed_json_dict[p_id]["verticalAnchor"],newFrame)
	if processed_json_dict[p_id]["fills"] != null && processed_json_dict[p_id]["fills"] != []:
		newLabelSettings.font_color = Color(processed_json_dict[p_id]["fills"][0]["color"]["r"],processed_json_dict[p_id]["fills"][0]["color"]["g"],processed_json_dict[p_id]["fills"][0]["color"]["b"])
	newLabelSettings.font_size = processed_json_dict[p_id]["fontSize"]
	if processed_json_dict[p_id]["border_color"] != []:
		newLabelSettings.outline_color = Color(processed_json_dict[p_id]["border_color"][0]["color"]["r"],processed_json_dict[p_id]["border_color"][0]["color"]["g"],processed_json_dict[p_id]["border_color"][0]["color"]["b"])
		newLabelSettings.outline_size = processed_json_dict[p_id]["fontStrokeWeight"] * 4
	
	# Nama node teks murni dari Figma
	newFrame.name = make_safeName(processed_json_dict[p_id]["name"])
	
	parent.add_child(newFrame)
	newFrame.set_label_settings(newLabelSettings)
	newFrame.set_owner(get_tree().get_edited_scene_root())
	newFrame.set_deferred("size", Vector2(processed_json_dict[p_id]["width"],processed_json_dict[p_id]["height"]))
	newFrame.set_deferred("position", Vector2(processed_json_dict[p_id]["x"],processed_json_dict[p_id]["y"]))
	newFrame.rotation_degrees = processed_json_dict[p_id]["rotation"] * -1
	newFrame.text = processed_json_dict[p_id]["characters"]
	update_textHAlign(processed_json_dict[p_id]["textAlignHorizontal"],newFrame)
	update_textVAlign(processed_json_dict[p_id]["textAlignVertical"],newFrame)
	if processed_json_dict[p_id]["layout_horiz_sizing"] != "FILL":
		newFrame.set_deferred("custom_minimum_size", Vector2(processed_json_dict[p_id]["width"],processed_json_dict[p_id]["height"]))
	else:
		newFrame.set_deferred("custom_minimum_size", Vector2(1.0,processed_json_dict[p_id]["height"]))
	newFrame.set_deferred("autowrap_mode", TextServer.AUTOWRAP_WORD_SMART)
	set_textwSize_fup(processed_json_dict[p_id]["layout_horiz_sizing"],newFrame)
	set_texthSize_fup(processed_json_dict[p_id]["layout_vert_sizing"],newFrame)

func place_component_inst(parent,p_id):
	var adjustedID = make_safeName(processed_json_dict[p_id]["master_comp"])
	var newComp = load(component_dictionary[adjustedID])
	var newFrame = newComp.instantiate()
	
	# Nama node component murni dari Figma
	newFrame.name = make_safeName(processed_json_dict[p_id]["name"])
	
	for key in processed_json_dict[p_id]["component_properties"].keys():
		if newFrame.has_meta(remove_after_hashtag(key)) != null:
			newFrame.set_deferred(remove_after_hashtag(key), processed_json_dict[p_id]["component_properties"][key]["value"])
	parent.add_child(newFrame)
	newFrame.set_owner(get_tree().get_edited_scene_root())
	newFrame.widthSizeMode = processed_json_dict[p_id]["layout_horiz_sizing"]
	newFrame.heightSizeMode = processed_json_dict[p_id]["layout_vert_sizing"]
	if processed_json_dict[p_id]["minWidth"] != null:
		newFrame.minSize.x = processed_json_dict[p_id]["minWidth"]
	else:
		newFrame.minSize.x = 0.0
	if processed_json_dict[p_id]["minHeight"] != null:
		newFrame.minSize.y = processed_json_dict[p_id]["minHeight"]
	else:
		newFrame.minSize.y = 0.0
	if processed_json_dict[p_id]["maxWidth"] != null:
		newFrame.maxSize.x = processed_json_dict[p_id]["maxWidth"]
	else:
		newFrame.maxSize.x = 100000.0
	if processed_json_dict[p_id]["maxHeight"] != null:
		newFrame.maxSize.y = processed_json_dict[p_id]["maxHeight"]
	else:
		newFrame.maxSize.y = 100000.0
	newFrame.set_deferred("size", Vector2(processed_json_dict[p_id]["width"],processed_json_dict[p_id]["height"]))
	if processed_json_dict[p_id]["layout_horiz_sizing"] == "FIXED" && processed_json_dict[p_id]["minWidth"] == null:
		newFrame.minSize.x = processed_json_dict[p_id]["width"]
	if processed_json_dict[p_id]["layout_vert_sizing"] == "FIXED" && processed_json_dict[p_id]["minHeight"] == null:
		newFrame.minSize.y = processed_json_dict[p_id]["height"]
	newFrame.set_deferred("position", Vector2(processed_json_dict[p_id]["x"],processed_json_dict[p_id]["y"]))
	newFrame.set_deferred("rotation_degrees", processed_json_dict[p_id]["rotation"] * -1)
	if processed_json_dict[p_id]["relativeTransform"][0][0] < 0:
		newFrame.scale.y *= -1
	if processed_json_dict[p_id]["relativeTransform"][1][1] < 0:
		newFrame.scale.y *= -1
	newFrame.set_deferred("center_rotation", true)
	newFrame.padding = processed_json_dict[p_id]["padding"]
	newFrame.widthSizeMode = processed_json_dict[p_id]["layout_horiz_sizing"]
	newFrame.heightSizeMode = processed_json_dict[p_id]["layout_vert_sizing"]
	newFrame.set_deferred("horizontalAnchor", processed_json_dict[p_id]["horizontalAnchor"])
	newFrame.set_deferred("verticalAnchor", processed_json_dict[p_id]["verticalAnchor"])
	pass

func checkParentLayoutNone(theParent):
	if processed_json_dict[theParent]["layout_mode"] != null:
		print(processed_json_dict[theParent]["name"])
		if processed_json_dict[theParent]["layout_mode"] == "NONE":
			return false
		else:
			return true
	else:
		return false

func process_colors(theColorsArray,theNode):
	for aFill in theColorsArray.size():
		if theColorsArray[aFill]["visible"] == true:
			match theColorsArray[aFill]["type"]:
				"SOLID":
					theNode.fill_color = Color(theColorsArray[aFill]["color"]["r"],theColorsArray[aFill]["color"]["g"],theColorsArray[aFill]["color"]["b"],theColorsArray[aFill]["opacity"])
					theNode.use_solid_fill = true
				"GRADIENT_LINEAR":
					var gradient = Gradient.new()
					for colorStop in theColorsArray[aFill]["gradientStops"].size():
						gradient.add_point(theColorsArray[aFill]["gradientStops"][colorStop]["position"], Color(theColorsArray[aFill]["gradientStops"][colorStop]["color"]["r"],theColorsArray[aFill]["gradientStops"][colorStop]["color"]["g"],theColorsArray[aFill]["gradientStops"][colorStop]["color"]["b"],theColorsArray[aFill]["gradientStops"][colorStop]["color"]["a"]))
					gradient.remove_point(1)
					gradient.remove_point(0)
					var gradient_texture = FigmaGradientTexture2D.new()
					gradient_texture.gradient = gradient
					gradient_texture.fill = GradientTexture2D.FILL_LINEAR
					gradient_texture.width = 64
					gradient_texture.height = 64
					gradient_texture.figma_transform_array = theColorsArray[aFill]["gradientTransform"]
					theNode.fill_gradient = gradient_texture
				"GRADIENT_RADIAL":
					var gradient = Gradient.new()
					for colorStop in theColorsArray[aFill]["gradientStops"].size():
						gradient.add_point(theColorsArray[aFill]["gradientStops"][colorStop]["position"], Color(theColorsArray[aFill]["gradientStops"][colorStop]["color"]["r"],theColorsArray[aFill]["gradientStops"][colorStop]["color"]["g"],theColorsArray[aFill]["gradientStops"][colorStop]["color"]["b"],theColorsArray[aFill]["gradientStops"][colorStop]["color"]["a"]))
					gradient.remove_point(1)
					gradient.remove_point(0)
					var gradient_texture = FigmaGradientTexture2D.new()
					gradient_texture.gradient = gradient
					gradient_texture.fill = GradientTexture2D.FILL_RADIAL
					gradient_texture.width = 64
					gradient_texture.height = 64
					gradient_texture.figma_transform_array = theColorsArray[aFill]["gradientTransform"]
					theNode.fill_gradient = gradient_texture
				"IMAGE":
					if images_folder != null and images_folder != "" and autoPlaceImages:
						var file_path = images_folder + "/"+theColorsArray[aFill]["imageHash"]+".png"
						if FileAccess.file_exists(file_path):
							var image_texture = load(file_path) as Texture
							if image_texture == null:
								push_warning("[FigmaImporter] Texture not imported yet: " + file_path)
								place_error_image(theNode)
								continue
							theNode.fill_texture = image_texture
							match theColorsArray[aFill]["scaleMode"]:
								"FIll":
									theNode.textureSizeMode = "Fill"
								"FIT":
									theNode.textureSizeMode = "Fit"
								"TILE":
									theNode.textureSizeMode = "Keep Size"
									theNode.tile_texture = true
									theNode.zoom = theColorsArray[aFill]["scalingFactor"]
								"CROP":
									theNode.textureSizeMode = "Keep Size"
									theNode.zoom = theColorsArray[aFill]["scalingFactor"]
						else:
							place_error_image(theNode)

func place_error_image(theNode)->void:
	var errorFile:String = script_dir + "/error_texture.png"
	var image_texture = load(errorFile) as Texture
	theNode.fill_texture = image_texture
	theNode.textureSizeMode = "Fill"

func renderRectangle(parent,p_id):
	pass
	print(p_id)

func remove_after_hashtag(input_string: String) -> String: 
	var hashtag_index = input_string.find("#") 
	if hashtag_index != -1: 
		return input_string.substr(0, hashtag_index) 
	return input_string

func changeTheFont(theFontName:String):
	pass
	var current_font = null
	var unused_font = load(fonts_folder+"/" + theFontName + ".ttf")
	var dynamicfont = get("custom_fonts/font")
	current_font = dynamicfont.font_data
	dynamicfont.font_data = unused_font
	unused_font = current_font

func update_textHAlign(_theVar,theNode):
	match _theVar:
		"LEFT":
			theNode.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		"CENTER":
			theNode.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		"RIGHT":
			theNode.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

func update_textVAlign(_theVar,theNode):
	match _theVar:
		"TOP":
			theNode.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		"CENTER":
			theNode.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		"BOTTOM":
			theNode.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM

func set_textwSize_fup(widthSizeMode,theNode)->void:
	match widthSizeMode:
		"HUG":
			theNode.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			theNode.size.x = 0.0
		"FIXED":
			theNode.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		"FILL":
			theNode.size_flags_horizontal = Control.SIZE_EXPAND_FILL

func set_texthSize_fup(heightSizeMode,theNode)->void:
	match heightSizeMode:
		"HUG":
			theNode.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			theNode.size.y = 0.0
		"FIXED":
			theNode.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		"FILL":
			theNode.size_flags_vertical = Control.SIZE_EXPAND_FILL


func test_key(the_dict,the_key:String):
	if the_dict is Dictionary and the_dict.has(the_key):
		return the_dict[the_key]
	return null

func strip_to_id(input_string:String):
	var start_pos = input_string.find("xIDx") + 4 
	var end_pos = input_string.rfind("x") 
	if start_pos < end_pos: 
		return input_string.substr(start_pos, end_pos - start_pos) 
	else:
		print("no id")

func make_safeName(the_name:String):
	var my_string:String = the_name
	my_string = my_string.replace(":","_")
	return(my_string)
	
func remove_spaces(incoming_string:String):
	var my_string:String = incoming_string
	my_string = my_string.replace(" ","")
	return(my_string)

func proc_halignments(_dicInfo):
	var newString:String = "Left"
	if _dicInfo != null:
		var whatProc = _dicInfo["horizontal"]
		match whatProc:
			"MIN":
				newString = "Left"
			"MAX":
				newString = "Right"
			"STRETCH":
				newString = "Left and Right"
			"CENTER":
				newString = "Center"
			"SCALE":
				newString = "Scale"
	return newString

func proc_valignments(_dicInfo):
	var newString:String = "Top"
	if _dicInfo != null:
		var whatProc = _dicInfo["vertical"]
		match whatProc:
			"MIN":
				newString = "Top"
			"MAX":
				newString = "Bottom"
			"STRETCH":
				newString = "Top and Bottom"
			"CENTER":
				newString = "Center"
			"SCALE":
				newString = "Scale"
	return newString

func proc_hlayoutAlign(_theWhat):
	pass
	var newString:String = "Left"
	if _theWhat != null:
		match _theWhat:
			"MIN":
				newString = "Left"
			"MAX":
				newString = "Right"
			"CENTER":
				newString = "Center"
	return newString
	
func proc_vlayoutAlign(_theWhat):
	pass
	var newString:String = "Top"
	if _theWhat != null:
		match _theWhat:
			"MIN":
				newString = "Top"
			"MAX":
				newString = "Bottom"
			"CENTER":
				newString = "Center"
	return newString

func set_anchor_horizontal_fup(horizontalAnchor:String,theNode)->void:
	var my_width = theNode.size.x
	var myHpos = theNode.position.x
	match horizontalAnchor:
		"Left":
			theNode.anchor_left = 0.0
			theNode.anchor_right = 0.0
			theNode.position.x = myHpos
			theNode.size.x = my_width
		"Center":
			theNode.anchor_left = 0.5
			theNode.anchor_right = 0.5
			theNode.position.x = myHpos
			theNode.size.x = my_width
		"Right":
			theNode.anchor_left = 1.0
			theNode.anchor_right = 1.0
			theNode.position.x = myHpos
			theNode.size.x = my_width
		"Left and Right":
			theNode.anchor_left = 0.0
			theNode.anchor_right = 1.0
			theNode.position.x = myHpos
			theNode.size.x = my_width
			theNode.grow_horizontal = Control.GROW_DIRECTION_BOTH
		"Scale":
			pass
			#need object bounds
			
func set_anchor_vertical_fup(verticalAnchor:String,theNode)->void:
	var my_height = theNode.size.y
	var myVpos = theNode.position.y
	match verticalAnchor:
		"Top":
			theNode.anchor_top = 0.0
			theNode.anchor_bottom = 0.0
			theNode.position.y = myVpos
			theNode.size.y = my_height
		"Center":
			theNode.anchor_top = 0.5
			theNode.anchor_bottom = 0.5
			theNode.position.y = myVpos
			theNode.size.y = my_height
		"Bottom":
			theNode.anchor_top = 1.0
			theNode.anchor_bottom = 1.0
			theNode.position.y = myVpos
			theNode.size.y = my_height
		"Top and Bottom":
			theNode.anchor_top = 0.0
			theNode.anchor_bottom = 1.0
			theNode.position.y = myVpos
			theNode.size.y = my_height
			theNode.grow_vertical = Control.GROW_DIRECTION_BOTH
		"Scale":
			pass
			#need object bounds
