/*
 * FileItemArchive.vala
 *
 * Copyright 2017 Tony George <teejeetech@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301, USA.
 *
 *
 */

using GLib;
using Gtk;
using Gee;
using Json;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

public class FileItemArchive : FileItem {

	// archive properties
	public int64 archive_size = 0;
	public int64 archive_unpacked_size = 0;
	public double compression_ratio = 0.0;
	public string archive_type = "";
	public string archive_method = "";
	public bool archive_is_encrypted = false;
	public bool archive_is_solid = false;
	public int archive_blocks = 0;
	public int64 archive_header_size = 0;
	public DateTime archive_modified;
	public string password = "";
	public string keyfile = "";

	public bool is_base = false;
	public FileItemArchive? archive_base_item; // for use by archived items
	public DateTime? cached_date = null;
	
	//public ArchiveTask task = null;
	public Gee.ArrayList<string> extract_list = new Gee.ArrayList<string>();
	public string extraction_path = "";
	
	public string error_msg = "";

	public override string display_path {
		owned get {

			if (_display_path.length > 0){
				return _display_path;
			}

			if (is_base){
				return file_path;
			}
			else {
				return path_combine(archive_base_item.display_path, file_path);
			}
		}
		set {
			_display_path = value;
		}
	}

	public bool is_archived_item {
		get {
			return !file_path.has_prefix("/");
		}
	}
	
	// contructors -------------------------------

	public FileItemArchive.from_path_and_type(string _file_path, FileType _file_type, bool _is_base) {

		file_path = _file_path;
		file_type = _file_type;
		is_base = _is_base;
		file_uri_scheme = "archive";
		object_count++;

		if (_is_base){
			archive_base_item = this;
			query_file_info();
		}
	}

	// static helpers ---------------------------------

	public static FileItemArchive? convert_file_item(FileItem item, FileType _file_type){

		log_debug("FileItemArchive: convert_file_item()");
		
		if (FileItem.is_archive_by_extension(item.file_path) && !FileItem.is_package_by_extension(item.file_path)){
			var arch = new FileItemArchive.from_path_and_type(item.file_path, FileType.DIRECTORY, true);
			if (item.parent != null){
				arch.parent = item.parent;
				arch.parent.children[arch.file_name] = arch;
			}
			arch.query_file_info();
			arch.file_type = _file_type;
			return arch;
		}
		return null;
	}
	
	// base class overrides ---------------------------------------------------

	public override void query_file_info() {
		if (is_base && file_exists(file_path)){
			base.query_file_info();
		}
		return;
	}
	
	public override void query_children(int depth = -1) {

		log_debug("FileItemArchive: query_children(): enter");
		
		/* Queries the file item's children using the file_path
		 * depth = -1, recursively find and add all children from disk
		 * depth =  1, find and add direct children
		 * depth =  0, meaningless, should not be used
		 * depth =  X, find and add children upto X levels
		 * */

		if (query_children_aborted) {
			log_debug("FileItemArchive: query_children(): query_children_aborted: return");
			return;
		}

		if (query_children_running) {
			log_debug("FileItemArchive: query_children(): query_children_running: return");
			return;
		}

		if (depth != -1) {
			log_debug("FileItemArchive: query_children(): depth != -1: return");
			return;
		}

		var file_date = file_get_modified_date(archive_base_item.file_path);
		if (dates_are_equal(cached_date, file_date)){
			log_debug("FileItemCloud: query_children(): skip");
			return;
		}
		
		// check if directory and continue -------------------
		
		if (!is_directory) {
			//query_file_info();
			query_children_running = false;
			query_children_pending = false;
			log_debug("FileItemArchive: query_children(): FileType != DIRECTORY");
			return;
		}

		log_debug("FileItemArchive: query_children(%d): %s".printf(depth, file_path), true);

		mutex_children.lock();

		if (depth < 0){
			dir_size_queried = false;
		}

		// query children ----------------------
		
		list_archive();
		
		// -------------------------------------

		update_counts();
		
		if (depth < 0){
			get_dir_size_recursively(true);
		}

		query_children_running = false;
		query_children_pending = false;

		mutex_children.unlock();
	}

	public override void query_children_async() {

		log_debug("FileItemArchive: query_children_async(): %s".printf(file_path));

		query_children_async_is_running = true;
		query_children_aborted = false;

		try {
			//start thread
			Thread.create<void> (query_children_async_thread, true);
		}
		catch (Error e) {
			log_error ("FileItemArchive: query_children_async(): error");
			log_error (e.message);
		}
	}

	private void query_children_async_thread() {
		log_debug("FileItemArchive: query_children_async_thread()");
		query_children(-1); // always add to cache
		query_children_async_is_running = false;
		//query_children_aborted = false; // reset
	}

	public override FileItem add_child(string item_file_path, FileType item_file_type, int64 item_size, 
		int64 item_size_compressed, bool item_query_file_info){

		//log_debug("FileItemArchive: add_child: %s ---------------".printf(item_file_path));

		FileItemArchive item = null;

		// check existing ----------------------------

		bool existing_file = false;

		string item_name = file_basename(item_file_path);
		
		if (children.has_key(item_name) && (children[item_name].file_name == item_name)){

			existing_file = true;
			item = (FileItemArchive) children[item_name];

			//log_debug("existing child, queried: %s".printf(item.fileinfo_queried.to_string()));
		}
		else{

			if (item == null){
				item = new FileItemArchive.from_path_and_type(item_file_path, item_file_type, false);
			}
			
			// set relationships
			item.parent = this;
			this.children[item.file_name] = item;
		}
		
		// set properties -----------------------------------
		
		item.set_properties();
		
		if (item.parent is FileItemArchive){
			item.archive_base_item = ((FileItemArchive) item.parent).archive_base_item;
		}
		
		item.is_stale = false; // mark fresh

		// ---------------------------------------------

		if (item_file_type == FileType.REGULAR) {

			//log_debug("add_child: regular file");

			item.file_size = item_size;

			// update hidden count -------------------------

			if (!existing_file){
				if (item.is_backup_or_hidden){
					this.hidden_count++;
				}
			}
		}
		else if (item_file_type == FileType.DIRECTORY) {

			//log_debug("add_child: directory");
		}

		return item;
	}

	// ----------------------------------------------------------
	
	public ArchiveTask list_archive(){
		var task = new ArchiveTask(window);
		task.open(this);
		return task;
	}

	/*private bool list_archive(){

		log_debug("FileItemArchive: list_archive(): %s".printf(this.file_path));
		log_debug("item.display_path: %s".printf(item.display_path));
		
		if (!item.file_path.has_prefix("/")){
			
			var action = extract_selected_item_to_temp_location(this.archive_base_item);
			
			action.task_complete.connect(()=>{
				
				string outpath = this.extraction_path;
				log_debug("outpath: %s".printf(outpath));
				
				string extracted_item_path = path_combine(outpath, this.file_path);
				log_debug("extracted_item_path: %s".printf(extracted_item_path));
				
				// set the display_path and change file_path to point to extracted_item_path
				item.display_path = item.display_path;
				item.file_path = extracted_item_path;
				log_debug("item.display_path: %s".printf(item.display_path));
				log_debug("item.file_path: %s".printf(item.file_path));
				//item.archive_base_item = item;
				// list the item
				//if (list_archive(item)){
				//	//set_view_item(item);
				//}
			});
			return false;
		}
		
		var task = item.list_archive();

		gtk_set_busy(true, window);
		while (task.status == AppStatus.RUNNING){
			sleep(200);
			gtk_do_events();
		}

		gtk_set_busy(false, window);

		log_debug("task.list_archive(): exit");
		
		if (task.status == AppStatus.PASSWORD_REQUIRED){

			if (prompt_for_password(item)){
				//restart
				return list_archive(item);
			}
			else{
				return false;
			}
		}
		else{
			FileItem.add_to_cache(item); // add file to cache as it has children
		}

		log_debug("list_archive(): exit");

		return true;
	}*/

	public bool prompt_for_password(Gtk.Window? window){

		log_debug("FileItemArchive: prompt_for_password()");

		bool wrong_pass = (password.length > 0);
		
		string msg = "<b>%s: %s</b>\n\n".printf(_("Encrypted archive"), file_name);
		
		if (wrong_pass){
			msg += "%s\n\n".printf(_("Password was wrong! Try again or Cancel"));
		}

		msg += _("Enter Password") + ":";
		
		password = PasswordDialog.prompt_user(window, false, "", msg);

		return (password.length > 0);
	}

	private void update_counts(){

		log_debug("FileItemArchive: update_counts()");

		// update counts --------------------------

		item_count = 0;
		file_count = 0;
		dir_count = 0;
		
		foreach(var child in children.values){
			if (child.is_directory){
				dir_count++;
			}
			else{
				file_count++;
			}
			item_count++;
		}
		children_queried = true;
	}

	protected void set_properties(){

		set_content_type_from_extension();
		
		can_read = true;
		can_write = false;
		can_execute = false;
		
		can_trash = false;
		can_delete = false;
		can_rename = false;

		owner_user = App.user_name;
		owner_group = App.user_name;
	}
}
