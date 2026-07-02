#!/usr/bin/env python3
import sys
import subprocess
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext, filedialog
import threading
import os
from urllib.parse import urlparse

class SettingsWindow:
    def __init__(self, parent):
        self.parent = parent
        self.download_path = tk.StringVar()
        
        # Get current working directory as default
        self.download_path.set(os.getcwd())
        
        self.create_window()
        
    def create_window(self):
        self.window = tk.Toplevel(self.parent)
        self.window.title("YouDown Settings")
        self.window.geometry("500x200")
        self.window.resizable(False, False)
        self.window.transient(self.parent)
        self.window.grab_set()
        
        # Center the window
        self.window.update_idletasks()
        x = (self.window.winfo_screenwidth() // 2) - (self.window.winfo_width() // 2)
        y = (self.window.winfo_screenheight() // 2) - (self.window.winfo_height() // 2)
        self.window.geometry(f"+{x}+{y}")
        
        # Main frame
        main_frame = ttk.Frame(self.window, padding="20")
        main_frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        
        # Title
        title_label = ttk.Label(main_frame, text="Download Settings", font=('Arial', 16, 'bold'))
        title_label.grid(row=0, column=0, columnspan=3, pady=(0, 20))
        
        # Download path section
        path_label = ttk.Label(main_frame, text="Download Path:", font=('Arial', 10, 'bold'))
        path_label.grid(row=1, column=0, sticky=tk.W, pady=(0, 5))
        
        # Path entry
        self.path_entry = ttk.Entry(main_frame, textvariable=self.download_path, width=50)
        self.path_entry.grid(row=2, column=0, columnspan=2, sticky=(tk.W, tk.E), padx=(0, 10))
        
        # Browse button
        browse_btn = ttk.Button(main_frame, text="...", width=3, command=self.browse_path)
        browse_btn.grid(row=2, column=2, sticky=tk.E)
        
        # Buttons frame
        button_frame = ttk.Frame(main_frame)
        button_frame.grid(row=3, column=0, columnspan=3, pady=(20, 0))
        
        # Save button
        save_btn = ttk.Button(button_frame, text="Save", command=self.save_settings)
        save_btn.grid(row=0, column=0, padx=(0, 10))
        
        # Cancel button
        cancel_btn = ttk.Button(button_frame, text="Cancel", command=self.window.destroy)
        cancel_btn.grid(row=0, column=1)
        
        # Configure grid weights
        main_frame.columnconfigure(0, weight=1)
        
    def browse_path(self):
        """Open folder browser dialog"""
        path = filedialog.askdirectory(
            title="Select Download Folder",
            initialdir=self.download_path.get()
        )
        if path:
            self.download_path.set(path)
            
    def save_settings(self):
        """Save the settings and close window"""
        path = self.download_path.get()
        if not os.path.exists(path):
            messagebox.showerror("Error", "Selected path does not exist!")
            return
            
        # Update parent's download path
        self.parent.download_path = path
        self.parent.log_message(f"Download path changed to: {path}")
        self.window.destroy()

class YouDownGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("YouDown - Video Downloader")
        self.root.geometry("700x500")
        self.root.configure(bg='#f0f0f0')
        
        # Set icon if available
        try:
            self.root.iconbitmap('icon.ico')
        except:
            pass
        
        self.APP = "y.exe"  # replace with your downloader executable name
        self.download_path = os.getcwd()  # Default to current directory
        
        self.setup_ui()
        self.setup_drag_drop()
        
    def setup_ui(self):
        # Main frame
        main_frame = ttk.Frame(self.root, padding="20")
        main_frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        
        # Configure grid weights
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)
        main_frame.columnconfigure(1, weight=1)
        main_frame.rowconfigure(3, weight=1)
        
        # Title and settings button frame
        title_frame = ttk.Frame(main_frame)
        title_frame.grid(row=0, column=0, columnspan=2, pady=(0, 10), sticky=(tk.W, tk.E))
        title_frame.columnconfigure(0, weight=1)
        
        # Title
        title_label = ttk.Label(title_frame, text="YouDown", font=('Arial', 24, 'bold'))
        title_label.grid(row=0, column=0, sticky=tk.W)
        
        # Settings button
        settings_btn = ttk.Button(title_frame, text="⚙", width=3, command=self.open_settings)
        settings_btn.grid(row=0, column=1, padx=(10, 0))
        
        # Instructions
        instructions = ttk.Label(main_frame, 
                               text="Enter video URLs (one per line) and click Download\nOr copy URLs and click 'Add from Clipboard'",
                               font=('Arial', 12))
        instructions.grid(row=1, column=0, columnspan=2, pady=(0, 20))
        
        # URL input area
        url_frame = ttk.LabelFrame(main_frame, text="Video URLs", padding="10")
        url_frame.grid(row=2, column=0, columnspan=2, sticky=(tk.W, tk.E), pady=(0, 10))
        url_frame.columnconfigure(0, weight=1)
        
        self.url_text = scrolledtext.ScrolledText(url_frame, height=6, font=('Arial', 10))
        self.url_text.grid(row=0, column=0, sticky=(tk.W, tk.E), pady=(0, 10))
        
        # Buttons frame
        button_frame = ttk.Frame(url_frame)
        button_frame.grid(row=1, column=0, sticky=(tk.W, tk.E))
        button_frame.columnconfigure(1, weight=1)
        
        # Add from Clipboard button (replaces drag & drop)
        add_btn = ttk.Button(button_frame, text="Add from Clipboard", command=self.add_from_clipboard)
        add_btn.grid(row=0, column=0, padx=(0, 10))
        
        # Paste button (replaces all content)
        paste_btn = ttk.Button(button_frame, text="Paste (Replace All)", command=self.paste_from_clipboard)
        paste_btn.grid(row=0, column=1, padx=(0, 10))
        
        # Clear button
        clear_btn = ttk.Button(button_frame, text="Clear", command=self.clear_urls)
        clear_btn.grid(row=0, column=2, padx=(0, 10))
        
        # Download button
        self.download_btn = ttk.Button(button_frame, text="Download All", command=self.download_all, style='Accent.TButton')
        self.download_btn.grid(row=0, column=3)
        
        # Log area
        log_frame = ttk.LabelFrame(main_frame, text="Download Log", padding="10")
        log_frame.grid(row=3, column=0, columnspan=2, sticky=(tk.W, tk.E, tk.N, tk.S), pady=(10, 0))
        log_frame.columnconfigure(0, weight=1)
        log_frame.rowconfigure(0, weight=1)
        
        self.log_text = scrolledtext.ScrolledText(log_frame, height=10, font=('Consolas', 9))
        self.log_text.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        
        # Status bar
        self.status_var = tk.StringVar()
        self.status_var.set("Ready")
        status_bar = ttk.Label(main_frame, textvariable=self.status_var, relief='sunken')
        status_bar.grid(row=4, column=0, columnspan=2, sticky=(tk.W, tk.E), pady=(10, 0))
        
        # Progress bar
        self.progress_var = tk.DoubleVar()
        self.progress_bar = ttk.Progressbar(main_frame, variable=self.progress_var, mode='determinate')
        self.progress_bar.grid(row=5, column=0, columnspan=2, sticky=(tk.W, tk.E), pady=(5, 0))
        
        # Bind keyboard shortcuts
        self.root.bind('<Control-Return>', lambda e: self.download_all())
        self.root.bind('<Control-v>', lambda e: self.add_from_clipboard())
        self.root.bind('<Control-a>', lambda e: self.select_all_urls())
        
    def open_settings(self):
        """Open the settings window"""
        SettingsWindow(self)
        
    def setup_drag_drop(self):
        """Setup simple clipboard monitoring"""
        # Check clipboard every 2 seconds for new URLs
        self.check_clipboard()
        
    def check_clipboard(self):
        """Periodically check clipboard for URLs"""
        try:
            # This is a simple approach - we'll just check periodically
            # In a real implementation, you'd use Windows hooks
            pass
        except:
            pass
        
        # Schedule next check
        self.root.after(2000, self.check_clipboard)
        
    def add_from_clipboard(self):
        """Add URLs from clipboard to existing list"""
        try:
            clipboard_text = self.root.clipboard_get()
            if not clipboard_text.strip():
                self.log_message("Clipboard is empty")
                return
                
            # Check if clipboard contains URLs
            urls = []
            for line in clipboard_text.split('\n'):
                line = line.strip()
                if line and self.is_valid_url(line):
                    urls.append(line)
            
            if urls:
                # Get existing URLs to check for duplicates
                current_text = self.url_text.get(1.0, tk.END).strip()
                existing_urls = []
                if current_text:
                    existing_urls = [url.strip() for url in current_text.split('\n') if url.strip()]
                
                # Filter out duplicates
                new_urls = []
                duplicates = []
               # for url in urls:
                  #  if url not in existing_urls:
                new_urls.append(url)
                 #   else:
                  #      duplicates.append(url)
                
                if new_urls:
                    # Add new URLs to the text area (append to existing)
                    if current_text:
                        # Add newline if there's existing content
                        new_text = current_text + '\n' + '\n'.join(new_urls)
                    else:
                        new_text = '\n'.join(new_urls)
                    
                    self.url_text.delete(1.0, tk.END)
                    self.url_text.insert(1.0, new_text)
                    
                    self.log_message(f"Added {len(new_urls)} new URL(s) from clipboard")
                    
                    if duplicates:
                        self.log_message(f"Skipped {len(duplicates)} duplicate URL(s)")
                else:
                    self.log_message("All URLs from clipboard are already in the list")
            else:
                self.log_message("No valid URLs found in clipboard")
                
        except Exception as e:
            self.log_message(f"Error reading clipboard: {e}")
    
    def paste_from_clipboard(self):
        """Replace all content with clipboard content"""
        try:
            clipboard_text = self.root.clipboard_get()
            self.url_text.delete(1.0, tk.END)
            self.url_text.insert(1.0, clipboard_text)
            self.log_message("Replaced URLs with clipboard content")
        except Exception as e:
            self.log_message(f"Error pasting from clipboard: {e}")
    
    def select_all_urls(self):
        """Select all text in URL area"""
        self.url_text.tag_add(tk.SEL, "1.0", tk.END)
        self.url_text.mark_set(tk.INSERT, "1.0")
        self.url_text.see(tk.INSERT)
        return 'break'
    
    def clear_urls(self):
        self.url_text.delete(1.0, tk.END)
    
    def download_all(self):
        urls_text = self.url_text.get(1.0, tk.END).strip()
        if not urls_text:
            messagebox.showwarning("Warning", "Please enter at least one video URL.")
            return
        
        urls = [url.strip() for url in urls_text.split('\n') if url.strip()]
        valid_urls = []
        
        for url in urls:
            if self.is_valid_url(url):
                valid_urls.append(url)
            else:
                self.log_message(f"Invalid URL: {url}")
        
        if not valid_urls:
            messagebox.showwarning("Warning", "No valid URLs found.")
            return
        
        # Disable download button during processing
        self.download_btn.configure(state='disabled')
        self.status_var.set(f"Downloading {len(valid_urls)} videos...")
        self.progress_var.set(0)
        
        # Run downloads in separate thread
        thread = threading.Thread(target=self.download_urls, args=(valid_urls,))
        thread.daemon = True
        thread.start()
    
    def download_urls(self, urls):
        total_urls = len(urls)
        successful_downloads = 0
        failed_downloads = 0
        
        for i, url in enumerate(urls):
            self.log_message(f"Processing ({i+1}/{total_urls}): {url}")
            
            try:
                # Change to download directory before running the command
                original_dir = os.getcwd()
                os.chdir(self.download_path)
                
                result = subprocess.run([self.APP, url], 
                                      capture_output=True, 
                                      text=True, 
                                      timeout=300)  # 5 minute timeout
                
                # Change back to original directory
                os.chdir(original_dir)
                
                if result.returncode == 0:
                    self.log_message(f"✓ Download completed: {url}")
                    successful_downloads += 1
                else:
                    self.log_message(f"✗ Download failed: {url}")
                    failed_downloads += 1
                    if result.stderr:
                        self.log_message(f"Error: {result.stderr}")
                        
            except subprocess.TimeoutExpired:
                self.log_message(f"✗ Download timeout: {url}")
                failed_downloads += 1
            except FileNotFoundError:
                self.log_message(f"✗ Error: {self.APP} not found. Make sure it's in the same directory.")
                break
            except Exception as e:
                self.log_message(f"✗ Unexpected error: {e}")
                failed_downloads += 1
            
            # Update progress
            progress = ((i + 1) / total_urls) * 100
            self.root.after(0, lambda p=progress: self.progress_var.set(p))
        
        # Re-enable download button and update status
        self.root.after(0, lambda: self.download_btn.configure(state='normal'))
        
        # Check if all downloads were successful
        if successful_downloads == total_urls and failed_downloads == 0:
            self.root.after(0, lambda: self.status_var.set("All downloads completed successfully!"))
            # Clear the URL field after successful completion
            self.root.after(0, lambda: self.url_text.delete(1.0, tk.END))
            self.root.after(0, lambda: self.log_message("URL field cleared after successful downloads"))
        else:
            self.root.after(0, lambda: self.status_var.set(f"Completed: {successful_downloads} successful, {failed_downloads} failed"))
        
        self.root.after(0, lambda: self.progress_var.set(0))
    
    def is_valid_url(self, url):
        """Check if URL is valid (supports any site)"""
        try:
            parsed = urlparse(url)
            return parsed.scheme in ['http', 'https'] and parsed.netloc
        except:
            return False
    
    def log_message(self, message):
        """Add message to log with timestamp"""
        import datetime
        timestamp = datetime.datetime.now().strftime("%H:%M:%S")
        log_entry = f"[{timestamp}] {message}\n"
        
        # Update GUI from main thread
        self.root.after(0, lambda: self.log_text.insert(tk.END, log_entry))
        self.root.after(0, lambda: self.log_text.see(tk.END))

def main():
    # Check if y.exe exists
    if not os.path.exists("y.exe"):
        messagebox.showerror("Error", "y.exe not found in the current directory.\nPlease make sure y.exe is in the same folder as this script.")
        return
    
    root = tk.Tk()
    app = YouDownGUI(root)
    
    # Center window on screen
    root.update_idletasks()
    x = (root.winfo_screenwidth() // 2) - (root.winfo_width() // 2)
    y = (root.winfo_screenheight() // 2) - (root.winfo_height() // 2)
    root.geometry(f"+{x}+{y}")
    
    root.mainloop()

if __name__ == "__main__":
    main()
