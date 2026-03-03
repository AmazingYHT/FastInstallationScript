#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
小说文本清理与切分工具 - 图形界面版本
支持选择txt文本和输出目录，支持清理和按章节切分
支持调用外部接口生成有声内容
"""

import re
import threading
import json
import requests
import time
from pathlib import Path
from datetime import datetime
import tkinter as tk
from tkinter import ttk, filedialog, scrolledtext, messagebox


class NovelCleanerGUI:
    """小说清理工具图形界面"""

    def __init__(self, root):
        self.root = root
        self.root.title("小说文本清理与切分工具")
        self.root.geometry("800x800")
        self.root.resizable(True, True)

        # 文本清理模式的变量
        self.input_file = None
        self.output_dir = None
        self.processing = False

        # 有声生成模式的变量
        self.novel_folder = None
        self.selected_files = []  # 多选的文件列表
        self.audio_output_dir = None
        self.audio_processing = False
        self.audio_paused = False
        self.audio_stopped = False
        self.current_index = 0  # 记录当前处理到第几个章节

        self.setup_ui()

    def setup_ui(self):
        """设置界面"""
        # 主容器 - 使用PanedWindow实现可拖动调整大小
        main_paned = ttk.PanedWindow(self.root, orient=tk.VERTICAL)
        main_paned.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

        # 上部区域（包含标题和选项卡）- 权重大，占更多空间
        top_frame = ttk.Frame(main_paned)
        main_paned.add(top_frame, weight=8)

        # 标题
        title_label = ttk.Label(top_frame, text="小说文本处理工具",
                               font=("Microsoft YaHei", 16, "bold"))
        title_label.pack(pady=(10, 5))

        # 使用Notebook创建两个选项卡
        self.notebook = ttk.Notebook(top_frame)
        self.notebook.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

        # 选项卡1: 文本清理与切分
        self.clean_tab = ttk.Frame(self.notebook)
        self.notebook.add(self.clean_tab, text="  文本清理与切分  ")
        self.setup_clean_tab()

        # 选项卡2: 生成有声
        self.audio_tab = ttk.Frame(self.notebook)
        self.notebook.add(self.audio_tab, text="  生成有声  ")
        self.setup_audio_tab()

        # 下部区域（日志）- 权重小，默认占较少空间，可拖动调整
        log_frame = ttk.LabelFrame(main_paned, text="处理日志", padding="3")
        main_paned.add(log_frame, weight=1)

        self.log_text = scrolledtext.ScrolledText(log_frame, font=("Consolas", 8), height=5)
        self.log_text.pack(fill=tk.BOTH, expand=True, padx=3, pady=3)

    def setup_clean_tab(self):
        """设置文本清理选项卡"""
        # 使用PanedWindow实现可拖动调整
        clean_paned = ttk.PanedWindow(self.clean_tab, orient=tk.VERTICAL)
        clean_paned.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

        # 上部区域（文件选择和选项）
        top_panel = ttk.Frame(clean_paned)
        clean_paned.add(top_panel, weight=1)

        # 文件选择区域
        file_frame = ttk.LabelFrame(top_panel, text="文件选择", padding="8")
        file_frame.pack(fill=tk.X, padx=5, pady=3)

        # 输入文件
        ttk.Label(file_frame, text="输入文件:").grid(row=0, column=0, sticky=tk.W, pady=3)
        self.file_entry = ttk.Entry(file_frame)
        self.file_entry.grid(row=0, column=1, sticky=tk.EW, padx=5, pady=3)
        ttk.Button(file_frame, text="浏览...", width=8, command=self.select_input_file).grid(row=0, column=2, pady=3)

        # 输出目录
        ttk.Label(file_frame, text="输出目录:").grid(row=1, column=0, sticky=tk.W, pady=3)
        self.dir_entry = ttk.Entry(file_frame)
        self.dir_entry.grid(row=1, column=1, sticky=tk.EW, padx=5, pady=3)
        ttk.Button(file_frame, text="浏览...", width=8, command=self.select_output_dir).grid(row=1, column=2, pady=3)

        file_frame.columnconfigure(1, weight=1)

        # 选项区域
        options_frame = ttk.LabelFrame(top_panel, text="处理选项", padding="8")
        options_frame.pack(fill=tk.X, padx=5, pady=3)

        # 处理模式
        self.mode_var = tk.StringVar(value="split")
        ttk.Radiobutton(options_frame, text="清理并按章节切分", variable=self.mode_var,
                       value="split").grid(row=0, column=0, sticky=tk.W, padx=15, pady=2)
        ttk.Radiobutton(options_frame, text="仅清理文本（不切分）", variable=self.mode_var,
                       value="clean").grid(row=0, column=1, sticky=tk.W, padx=15, pady=2)

        # 编码选择
        ttk.Label(options_frame, text="文件编码:").grid(row=1, column=0, sticky=tk.W, padx=15, pady=2)
        self.encoding_var = tk.StringVar(value="auto")
        encoding_combo = ttk.Combobox(options_frame, textvariable=self.encoding_var,
                                     values=["auto", "utf-8", "gbk", "gb18030"], width=12, state="readonly")
        encoding_combo.grid(row=1, column=1, sticky=tk.W, padx=15, pady=2)

        # 自定义清理字符
        ttk.Label(options_frame, text="自定义清理字符:").grid(row=2, column=0, sticky=tk.W, padx=15, pady=2)
        self.custom_chars_var = tk.StringVar(value="")
        custom_chars_entry = ttk.Entry(options_frame, textvariable=self.custom_chars_var)
        custom_chars_entry.grid(row=2, column=1, sticky=tk.EW, padx=15, pady=2)
        ttk.Label(options_frame, text="(多个字符用逗号分隔)", foreground="gray",
                 font=("Microsoft YaHei", 8)).grid(row=2, column=2, sticky=tk.W, padx=5, pady=2)

        # 快捷预设按钮
        preset_frame = ttk.Frame(options_frame)
        preset_frame.grid(row=3, column=0, columnspan=3, sticky=tk.EW, padx=10, pady=3)
        ttk.Label(preset_frame, text="快捷预设:").pack(side=tk.LEFT, padx=(0, 5))
        ttk.Button(preset_frame, text="特殊符号", width=8,
                  command=lambda: self.custom_chars_var.set("※,☆,★,♡,♥,◆,◇,■,□,▲,△,▼,▽")).pack(side=tk.LEFT, padx=1)
        ttk.Button(preset_frame, text="网络表情", width=8,
                  command=lambda: self.custom_chars_var.set("(笑)(哭)(怒)(汗)")).pack(side=tk.LEFT, padx=1)
        ttk.Button(preset_frame, text="广告词", width=8,
                  command=lambda: self.custom_chars_var.set("本章完,求订阅,求推荐,求收藏,请关注")).pack(side=tk.LEFT, padx=1)
        ttk.Button(preset_frame, text="清空", width=6,
                  command=lambda: self.custom_chars_var.set("")).pack(side=tk.LEFT, padx=1)

        options_frame.columnconfigure(1, weight=1)

        # 下部区域（操作按钮和进度）
        bottom_panel = ttk.Frame(clean_paned)
        clean_paned.add(bottom_panel, weight=0)

        # 操作按钮
        button_frame = ttk.Frame(bottom_panel)
        button_frame.pack(fill=tk.X, padx=5, pady=5)

        self.process_btn = ttk.Button(button_frame, text="开始处理", command=self.start_processing, width=12)
        self.process_btn.pack(side=tk.LEFT, padx=3)

        ttk.Button(button_frame, text="清空日志", command=self.clear_log, width=10).pack(side=tk.LEFT, padx=3)
        ttk.Button(button_frame, text="退出", command=self.root.quit, width=8).pack(side=tk.RIGHT, padx=3)

        # 进度条
        self.progress = ttk.Progressbar(bottom_panel, mode='indeterminate')
        self.progress.pack(fill=tk.X, padx=5, pady=(0, 5))

    def setup_audio_tab(self):
        """设置有声生成选项卡"""
        # 使用PanedWindow实现可拖动调整
        audio_paned = ttk.PanedWindow(self.audio_tab, orient=tk.VERTICAL)
        audio_paned.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

        # 上部滚动区域（包含所有配置）
        top_canvas = tk.Canvas(audio_paned, highlightthickness=0)
        scrollbar = ttk.Scrollbar(audio_paned, orient="vertical", command=top_canvas.yview)
        scrollable_frame = ttk.Frame(top_canvas)

        scrollable_frame.bind(
            "<Configure>",
            lambda e: top_canvas.configure(scrollregion=top_canvas.bbox("all"))
        )

        # 绑定Canvas大小变化事件，确保scrollable_frame宽度始终填满
        def on_canvas_configure(event):
            canvas_width = event.width
            top_canvas.itemconfig("scrollable_window", width=canvas_width)

        top_canvas.bind("<Configure>", on_canvas_configure)
        top_canvas.create_window((0, 0), window=scrollable_frame, anchor="nw", tags="scrollable_window", width=top_canvas.winfo_width())
        top_canvas.configure(yscrollcommand=scrollbar.set)

        audio_paned.add(top_canvas, weight=3)

        # 源文件选择区域
        file_frame = ttk.LabelFrame(scrollable_frame, text="源文件选择", padding="8")
        file_frame.pack(fill=tk.BOTH, expand=True, padx=5, pady=3)

        # 选择模式
        self.input_mode_var = tk.StringVar(value="folder")
        ttk.Radiobutton(file_frame, text="选择文件夹（处理所有txt）", variable=self.input_mode_var,
                       value="folder", command=self.on_input_mode_changed).grid(row=0, column=0, columnspan=3, sticky=tk.W, pady=2)
        ttk.Radiobutton(file_frame, text="多选文件（选择指定txt）", variable=self.input_mode_var,
                       value="files", command=self.on_input_mode_changed).grid(row=1, column=0, columnspan=3, sticky=tk.W, pady=2)

        # 文件夹选择行
        ttk.Label(file_frame, text="小说文件夹:").grid(row=2, column=0, sticky=tk.W, pady=3)
        self.folder_entry = ttk.Entry(file_frame)
        self.folder_entry.grid(row=2, column=1, sticky=tk.EW, padx=5, pady=3)
        self.folder_btn = ttk.Button(file_frame, text="浏览...", width=8, command=self.select_novel_folder)
        self.folder_btn.grid(row=2, column=2, pady=3)

        # 多选文件行
        ttk.Label(file_frame, text="选择文件:").grid(row=3, column=0, sticky=tk.W, pady=3)
        self.files_entry = ttk.Entry(file_frame)
        self.files_entry.grid(row=3, column=1, sticky=tk.EW, padx=5, pady=3)
        self.files_btn = ttk.Button(file_frame, text="多选...", width=8, command=self.select_multiple_files)
        self.files_btn.grid(row=3, column=2, pady=3)

        # 已选文件数量显示
        self.selected_files_label = ttk.Label(file_frame, text="", foreground="gray")
        self.selected_files_label.grid(row=4, column=0, columnspan=3, sticky=tk.W, pady=2, padx=5)

        # 音频输出目录
        ttk.Label(file_frame, text="音频输出目录:").grid(row=5, column=0, sticky=tk.W, pady=3)
        self.audio_output_entry = ttk.Entry(file_frame)
        self.audio_output_entry.grid(row=5, column=1, sticky=tk.EW, padx=5, pady=3)
        ttk.Button(file_frame, text="浏览...", width=8, command=self.select_audio_output_dir).grid(row=5, column=2, pady=3)

        # 配置列权重，让Entry所在列可以拉伸
        file_frame.columnconfigure(1, weight=1)

        # API配置区域
        api_frame = ttk.LabelFrame(scrollable_frame, text="API配置", padding="8")
        api_frame.pack(fill=tk.BOTH, expand=True, padx=5, pady=3)

        ttk.Label(api_frame, text="API地址:").grid(row=0, column=0, sticky=tk.W, pady=3)
        self.api_url_entry = ttk.Entry(api_frame)
        self.api_url_entry.insert(0, "http://127.0.0.1:3000/api/v1/tts/generateJson")
        self.api_url_entry.grid(row=0, column=1, sticky=tk.EW, padx=5, pady=3)
        api_frame.columnconfigure(1, weight=1)

        # 语音参数配置
        params_frame = ttk.LabelFrame(scrollable_frame, text="语音参数", padding="8")
        params_frame.pack(fill=tk.BOTH, expand=True, padx=5, pady=3)

        # Voice选择
        ttk.Label(params_frame, text="语音:").grid(row=0, column=0, sticky=tk.W, pady=3)
        self.voice_var = tk.StringVar(value="zh-CN-YunxiNeural")

        self.voice_list = [
            ("zh-CN-XiaoxiaoNeural", "女声-新闻/小说"),
            ("zh-CN-XiaoyiNeural", "女声-卡通/小说"),
            ("zh-CN-YunjianNeural", "男声-体育/小说"),
            ("zh-CN-YunxiNeural", "男声-小说"),
            ("zh-CN-YunxiaNeural", "男声-卡通/小说"),
            ("zh-CN-YunyangNeural", "男声-新闻"),
            ("zh-CN-liaoning-XiaobeiNeural", "女声-东北话"),
            ("zh-CN-shaanxi-XiaoniNeural", "女声-陕西话"),
            ("zh-HK-HiuGaaiNeural", "女声-粤语(香港)"),
            ("zh-HK-HiuMaanNeural", "女声-粤语(香港)"),
            ("zh-HK-WanLungNeural", "男声-粤语(香港)"),
        ]

        voice_combo = ttk.Combobox(params_frame, textvariable=self.voice_var, width=25,
                                  values=[v[0] for v in self.voice_list], state="readonly")
        voice_combo.grid(row=0, column=1, sticky=tk.W, pady=3, padx=5)

        self.voice_desc_var = tk.StringVar(value="男声-小说")
        voice_desc_label = ttk.Label(params_frame, textvariable=self.voice_desc_var,
                                    foreground="gray", font=("Microsoft YaHei", 8))
        voice_desc_label.grid(row=0, column=2, sticky=tk.W, padx=5, pady=3)
        voice_combo.bind("<<ComboboxSelected>>", self.on_voice_selected)

        # Rate - 滑动条
        ttk.Label(params_frame, text="语速:").grid(row=1, column=0, sticky=tk.W, pady=3)
        self.rate_value = tk.IntVar(value=0)
        self.rate_var = tk.StringVar(value="0%")
        rate_scale = ttk.Scale(params_frame, from_=-99, to=99, variable=self.rate_value,
                              orient=tk.HORIZONTAL, command=lambda v: self.rate_var.set(f"{int(float(v))}%"))
        rate_scale.grid(row=1, column=1, sticky=tk.EW, pady=3, padx=5)
        self.rate_label = ttk.Label(params_frame, text="0%", width=6)
        self.rate_label.grid(row=1, column=2, sticky=tk.W, padx=5)
        self.rate_value.trace_add("write", lambda *args: self.rate_label.config(text=f"{self.rate_value.get()}%"))

        # Pitch - 滑动条
        ttk.Label(params_frame, text="音调:").grid(row=2, column=0, sticky=tk.W, pady=3)
        self.pitch_value = tk.IntVar(value=0)
        self.pitch_var = tk.StringVar(value="0Hz")
        pitch_scale = ttk.Scale(params_frame, from_=-99, to=99, variable=self.pitch_value,
                               orient=tk.HORIZONTAL, command=lambda v: self.pitch_var.set(f"{int(float(v))}Hz"))
        pitch_scale.grid(row=2, column=1, sticky=tk.EW, pady=3, padx=5)
        self.pitch_label = ttk.Label(params_frame, text="0Hz", width=6)
        self.pitch_label.grid(row=2, column=2, sticky=tk.W, padx=5)
        self.pitch_value.trace_add("write", lambda *args: self.pitch_label.config(text=f"{self.pitch_value.get()}Hz"))

        # Volume - 滑动条
        ttk.Label(params_frame, text="音量:").grid(row=3, column=0, sticky=tk.W, pady=3)
        self.volume_value = tk.IntVar(value=0)
        self.volume_var = tk.StringVar(value="0%")
        volume_scale = ttk.Scale(params_frame, from_=-99, to=99, variable=self.volume_value,
                                orient=tk.HORIZONTAL, command=lambda v: self.volume_var.set(f"{int(float(v))}%"))
        volume_scale.grid(row=3, column=1, sticky=tk.EW, pady=3, padx=5)
        self.volume_label = ttk.Label(params_frame, text="0%", width=6)
        self.volume_label.grid(row=3, column=2, sticky=tk.W, padx=5)
        self.volume_value.trace_add("write", lambda *args: self.volume_label.config(text=f"{self.volume_value.get()}%"))

        # 重置按钮
        ttk.Button(params_frame, text="重置参数", command=self.reset_voice_params, width=12).grid(row=4, column=0, columnspan=3, pady=5)

        params_frame.columnconfigure(1, weight=1)

        # 下部区域（操作按钮和进度）
        bottom_panel = ttk.Frame(audio_paned)
        audio_paned.add(bottom_panel, weight=0)

        # 操作按钮
        button_frame = ttk.Frame(bottom_panel)
        button_frame.pack(fill=tk.X, padx=5, pady=5)

        self.audio_process_btn = ttk.Button(button_frame, text="开始生成有声",
                                           command=self.start_audio_processing, width=12)
        self.audio_process_btn.pack(side=tk.LEFT, padx=2)

        self.audio_pause_btn = ttk.Button(button_frame, text="暂停",
                                         command=self.toggle_pause, state=tk.DISABLED, width=8)
        self.audio_pause_btn.pack(side=tk.LEFT, padx=2)

        self.audio_stop_btn = ttk.Button(button_frame, text="停止",
                                        command=self.stop_audio_processing, state=tk.DISABLED, width=8)
        self.audio_stop_btn.pack(side=tk.LEFT, padx=2)

        ttk.Button(button_frame, text="清空日志", command=self.clear_log, width=10).pack(side=tk.LEFT, padx=2)
        ttk.Button(button_frame, text="退出", command=self.root.quit, width=8).pack(side=tk.RIGHT, padx=2)

        # 进度条
        self.audio_progress = ttk.Progressbar(bottom_panel, mode='indeterminate')
        self.audio_progress.pack(fill=tk.X, padx=5, pady=(0, 5))

        # 鼠标滚轮支持 - 只在配置区域绑定，不影响日志区域
        def _on_mousewheel(event):
            top_canvas.yview_scroll(int(-1*(event.delta/120)), "units")

        # 绑定到canvas和scrollable_frame，不使用bind_all
        top_canvas.bind("<MouseWheel>", _on_mousewheel)
        scrollable_frame.bind("<MouseWheel>", _on_mousewheel)

        # 初始化输入模式状态（默认文件夹模式，禁用多选文件）
        self.on_input_mode_changed()

    def log(self, message):
        """添加日志"""
        self.log_text.insert(tk.END, f"[{datetime.now().strftime('%H:%M:%S')}] {message}\n")
        self.log_text.see(tk.END)
        self.root.update_idletasks()

    def clear_log(self):
        """清空日志"""
        self.log_text.delete(1.0, tk.END)

    # ============= 文本清理模式相关方法 =============

    def select_input_file(self):
        """选择输入文件"""
        filename = filedialog.askopenfilename(
            title="选择小说文本文件",
            filetypes=[("文本文件", "*.txt"), ("所有文件", "*.*")]
        )
        if filename:
            self.input_file = filename
            self.file_entry.delete(0, tk.END)
            self.file_entry.insert(0, filename)
            # 自动设置输出目录
            if not self.output_dir:
                default_output = str(Path(filename).parent / f"{Path(filename).stem}_分章")
                self.dir_entry.delete(0, tk.END)
                self.dir_entry.insert(0, default_output)
                self.output_dir = default_output

    def select_output_dir(self):
        """选择输出目录"""
        dirname = filedialog.askdirectory(title="选择输出目录")
        if dirname:
            self.output_dir = dirname
            self.dir_entry.delete(0, tk.END)
            self.dir_entry.insert(0, dirname)

    def start_processing(self):
        """开始处理"""
        if self.processing:
            return

        if not self.input_file or not Path(self.input_file).exists():
            self.log("错误: 请先选择有效的输入文件")
            return

        self.processing = True
        self.process_btn.config(state=tk.DISABLED)
        self.progress.start()

        # 在后台线程处理
        thread = threading.Thread(target=self.process_file)
        thread.daemon = True
        thread.start()

    def process_file(self):
        """处理文件（后台线程）"""
        try:
            split_mode = self.mode_var.get() == "split"
            encoding = self.encoding_var.get()

            if split_mode:
                self.split_novel_by_chapters(self.input_file, self.output_dir, encoding)
            else:
                self.clean_novel_text(self.input_file, self.output_dir, encoding)

            self.log("\n✓ 处理完成!")

        except Exception as e:
            self.log(f"\n✗ 处理出错: {e}")
        finally:
            self.processing = False
            self.root.after(0, self.process_done)

    def process_done(self):
        """处理完成"""
        self.progress.stop()
        self.process_btn.config(state=tk.NORMAL)

    def read_file(self, filepath, encoding):
        """读取文件内容"""
        path = Path(filepath)

        if encoding == "auto":
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    return f.read()
            except UnicodeDecodeError:
                try:
                    with open(path, 'r', encoding='gbk') as f:
                        self.log("使用 GBK 编码读取")
                        return f.read()
                except:
                    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                        self.log("使用 UTF-8 (忽略错误) 编码读取")
                        return f.read()
        else:
            with open(path, 'r', encoding=encoding, errors='ignore') as f:
                return f.read()

    def clean_text(self, content):
        """清理文本中的连续分隔符和自定义字符"""
        original_size = len(content)

        # 去除 10 个以上的连续 = 或 -
        content = re.sub(r'={10,}', '', content)
        content = re.sub(r'-{10,}', '', content)
        content = re.sub(r'[-=]{10,}', '', content)

        # 处理自定义清理字符
        custom_chars = self.custom_chars_var.get().strip()
        if custom_chars:
            # 解析用户输入的字符，支持逗号分隔
            # 移除空格后按逗号分割
            chars_to_remove = [c.strip() for c in custom_chars.replace('，', ',').split(',') if c.strip()]

            if chars_to_remove:
                # 打印清理信息
                self.log(f"  清理自定义字符: {', '.join(repr(c) for c in chars_to_remove)}")

                # 对每个字符进行清理（转义正则特殊字符）
                for char in chars_to_remove:
                    # 转义正则特殊字符
                    escaped_char = re.escape(char)
                    # 移除所有该字符
                    content = re.sub(escaped_char, '', content)

        # 清理空行（保留最多2个连续空行）
        content = re.sub(r'\n\s*\n\s*\n+', '\n\n\n', content)

        removed = original_size - len(content)
        return content, removed

    def detect_chapter_pattern(self, content):
        """检测章节标题模式"""
        patterns = [
            # 第X章（支持空格：第1章、第 1 章、第  1  章）
            (r'^第\s*[零一二三四五六七八九十百千万0-9]+\s*[章回卷节集部篇].*$', "第X章"),
            # 数字、标题
            (r'^[零一二三四五六七八九十百千万0-9]+\s*、.*$', "数字、"),
            # Chapter X
            (r'^Chapter\s+\d+.*$', "Chapter"),
            # 卷X
            (r'^卷\s*[零一二三四五六七八九十百千万0-9]+.*$', "卷X"),
            # 序章/番外
            (r'^(序言|前言|引言|楔子|尾声|后记|番外|目录|正文)$', "序章/番外"),
        ]

        best_pattern = None
        max_matches = 0
        best_name = ""

        for pattern, name in patterns:
            matches = len(re.findall(pattern, content, re.MULTILINE))
            if matches > max_matches:
                max_matches = matches
                best_pattern = pattern
                best_name = name

        return best_pattern, max_matches, best_name

    def split_chapters(self, content, pattern):
        """按章节切分文本"""
        chapters = []
        for match in re.finditer(pattern, content, re.MULTILINE):
            title = match.group(0).strip()
            start_pos = match.start()
            chapters.append({'title': title, 'pos': start_pos})

        if not chapters:
            return None

        chapter_contents = []
        for i, chapter in enumerate(chapters):
            title = chapter['title']
            start = chapter['pos']
            end = chapters[i + 1]['pos'] if i < len(chapters) - 1 else len(content)
            chapter_content = content[start:end].strip()
            chapter_contents.append({'title': title, 'content': chapter_content})

        return chapter_contents

    def sanitize_filename(self, filename):
        """清理文件名"""
        illegal_chars = r'[<>:"/\\|?*]'
        filename = re.sub(illegal_chars, '_', filename)
        if len(filename) > 200:
            filename = filename[:200]
        return filename.strip()

    def clean_novel_text(self, input_file, output_dir, encoding):
        """清理小说文本（不切分）"""
        self.log(f"正在读取文件: {input_file}")
        content = self.read_file(input_file, encoding)

        original_size = len(content)
        self.log(f"原始文件大小: {original_size:,} 字符")

        self.log("正在清理文本...")
        content, removed = self.clean_text(content)

        self.log(f"清理后大小: {len(content):,} 字符")
        self.log(f"移除字符: {removed:,} 字符")

        # 确定输出文件
        input_path = Path(input_file)
        if output_dir:
            output_path = Path(output_dir) / input_path.name
        else:
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            output_path = input_path.parent / f"{input_path.stem}_已清理_{timestamp}{input_path.suffix}"

        output_path.parent.mkdir(parents=True, exist_ok=True)

        self.log(f"正在写入文件: {output_path}")
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(content)

    def split_novel_by_chapters(self, input_file, output_dir, encoding):
        """清理并按章节切分小说"""
        input_path = Path(input_file)

        self.log(f"正在读取文件: {input_file}")
        content = self.read_file(input_file, encoding)

        original_size = len(content)
        self.log(f"原始文件大小: {original_size:,} 字符")

        self.log("正在清理文本...")
        content, removed = self.clean_text(content)
        self.log(f"清理完成，移除 {removed:,} 字符")

        # 检测章节
        self.log("正在检测章节...")
        pattern, count, pattern_name = self.detect_chapter_pattern(content)

        if count == 0:
            self.log("未检测到章节标题，尝试使用备用模式...")
            pattern = r'^(第[零一二三四五六七八九十百千万0-9]+[章回卷节集部篇].*)$'
            pattern_name = "默认模式"
            count = len(re.findall(pattern, content, re.MULTILINE))

        self.log(f"使用模式: {pattern_name}")
        self.log(f"检测到 {count} 个章节标题")

        self.log("正在切分章节...")
        chapters = self.split_chapters(content, pattern)

        if not chapters:
            self.log("未检测到章节，无法切分")
            return

        # 确定输出目录
        if output_dir:
            out_path = Path(output_dir)
        else:
            out_path = input_path.parent / f"{input_path.stem}_分章"

        out_path.mkdir(parents=True, exist_ok=True)

        # 保存每个章节
        self.log(f"正在保存 {len(chapters)} 个章节到: {out_path}")
        for i, chapter in enumerate(chapters, 1):
            title = chapter['title']
            chapter_content = chapter['content']

            safe_title = self.sanitize_filename(title)
            filename = f"{i:04d}_{safe_title}.txt"
            filepath = out_path / filename

            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(chapter_content)

            self.log(f"  [{i}/{len(chapters)}] {title}")

        self.log(f"\n完成! 共保存 {len(chapters)} 个章节")
        self.log(f"输出目录: {out_path}")

    # ============= 有声生成模式相关方法 =============

    def on_voice_selected(self, event):
        """语音选择回调"""
        selected = self.voice_var.get()
        for voice_name, desc in self.voice_list:
            if voice_name == selected:
                self.voice_desc_var.set(desc)
                break

    def reset_voice_params(self):
        """重置语音参数为默认值"""
        # 重置语音选择
        self.voice_var.set("zh-CN-YunxiNeural")
        self.voice_desc_var.set("男声-小说")
        # 重置滑动条
        self.rate_value.set(0)
        self.pitch_value.set(0)
        self.volume_value.set(0)
        self.rate_var.set("0%")
        self.pitch_var.set("0Hz")
        self.volume_var.set("0%")

    def on_input_mode_changed(self):
        """输入模式切换回调"""
        mode = self.input_mode_var.get()
        if mode == "folder":
            # 文件夹模式：启用文件夹选择，禁用文件选择
            self.folder_entry.config(state=tk.NORMAL)
            self.folder_btn.config(state=tk.NORMAL)
            self.files_entry.config(state=tk.DISABLED)
            self.files_btn.config(state=tk.DISABLED)
        else:
            # 多选文件模式：禁用文件夹选择，启用文件选择
            self.folder_entry.config(state=tk.DISABLED)
            self.folder_btn.config(state=tk.DISABLED)
            self.files_entry.config(state=tk.NORMAL)
            self.files_btn.config(state=tk.NORMAL)

    def select_multiple_files(self):
        """多选txt文件"""
        filenames = filedialog.askopenfilenames(
            title="选择要生成有声的txt文件（可多选）",
            filetypes=[("文本文件", "*.txt"), ("所有文件", "*.*")]
        )
        if filenames:
            self.selected_files = list(filenames)
            # 显示选择的文件数量
            folder_paths = set()
            for f in self.selected_files:
                folder_paths.add(str(Path(f).parent))

            # 如果所有文件在同一文件夹，显示该文件夹
            if len(folder_paths) == 1:
                folder = list(folder_paths)[0]
                self.files_entry.delete(0, tk.END)
                self.files_entry.insert(0, folder)
            else:
                self.files_entry.delete(0, tk.END)
                self.files_entry.insert(0, f"{len(self.selected_files)} 个文件来自不同文件夹")

            # 更新标签
            self.selected_files_label.config(text=f"已选择 {len(self.selected_files)} 个文件")

            # 自动设置音频输出目录
            if not self.audio_output_dir and len(folder_paths) == 1:
                default_output = str(list(folder_paths)[0]) + "_audio"
                self.audio_output_entry.delete(0, tk.END)
                self.audio_output_entry.insert(0, default_output)
                self.audio_output_dir = default_output

    def select_novel_folder(self):
        """选择小说文件夹（章节txt所在目录）"""
        dirname = filedialog.askdirectory(title="选择小说章节文件夹")
        if dirname:
            self.novel_folder = dirname
            self.folder_entry.delete(0, tk.END)
            self.folder_entry.insert(0, dirname)
            # 自动设置音频输出目录
            if not self.audio_output_dir:
                default_output = str(Path(dirname) / "audio")
                self.audio_output_entry.delete(0, tk.END)
                self.audio_output_entry.insert(0, default_output)
                self.audio_output_dir = default_output

    def select_audio_output_dir(self):
        """选择音频输出目录"""
        dirname = filedialog.askdirectory(title="选择音频输出目录")
        if dirname:
            self.audio_output_dir = dirname
            self.audio_output_entry.delete(0, tk.END)
            self.audio_output_entry.insert(0, dirname)

    def start_audio_processing(self):
        """开始生成有声"""
        if self.audio_processing and not self.audio_paused:
            return

        # 如果是从暂停状态恢复
        if self.audio_paused:
            self.audio_paused = False
            self.audio_pause_btn.config(text="暂停")
            self.log("继续生成...")
            return

        # 检查输入源
        mode = self.input_mode_var.get()
        if mode == "folder":
            if not self.novel_folder or not Path(self.novel_folder).exists():
                self.log("错误: 请先选择有效的小说文件夹")
                return
        else:  # files mode
            if not self.selected_files:
                self.log("错误: 请先选择要处理的txt文件")
                return

        self.audio_processing = True
        self.audio_paused = False
        self.audio_stopped = False
        self.current_index = 0
        self.audio_process_btn.config(state=tk.DISABLED)
        self.audio_pause_btn.config(state=tk.NORMAL)
        self.audio_stop_btn.config(state=tk.NORMAL)
        self.audio_progress.start()

        # 在后台线程处理
        thread = threading.Thread(target=self.process_audio_generation)
        thread.daemon = True
        thread.start()

    def toggle_pause(self):
        """切换暂停/继续状态"""
        if self.audio_paused:
            # 恢复
            self.audio_paused = False
            self.audio_pause_btn.config(text="暂停")
            self.log("继续生成...")
        else:
            # 暂停
            self.audio_paused = True
            self.audio_pause_btn.config(text="继续")
            self.log("已暂停，点击[继续]按钮恢复...")

    def stop_audio_processing(self):
        """停止生成"""
        self.audio_stopped = True
        self.audio_paused = False
        self.log("正在停止...")

    def process_audio_done(self):
        """音频处理完成"""
        self.audio_progress.stop()
        self.audio_processing = False
        self.audio_paused = False
        self.audio_stopped = False
        self.audio_process_btn.config(state=tk.NORMAL)
        self.audio_pause_btn.config(state=tk.DISABLED, text="暂停")
        self.audio_stop_btn.config(state=tk.DISABLED)

    def get_chapter_files(self, folder_path):
        """获取文件夹中的所有章节文件"""
        folder = Path(folder_path)
        txt_files = list(folder.glob("*.txt"))

        # 按文件名排序
        txt_files.sort(key=lambda x: x.name)

        return txt_files

    def read_chapter_content(self, filepath):
        """读取章节内容"""
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                return f.read()
        except UnicodeDecodeError:
            try:
                with open(filepath, 'r', encoding='gbk') as f:
                    return f.read()
            except:
                with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                    return f.read()

    def call_tts_api(self, text, api_url, voice, rate, pitch, volume):
        """调用TTS API生成音频（流式接口格式）"""
        # 构建请求体（新接口格式）
        payload = {
            "data": [
                {
                    "desc": "有声小说",
                    "text": text,
                    "voice": voice,
                    "rate": rate,
                    "pitch": pitch,
                    "volume": volume
                }
            ]
        }

        # 打印请求详情（便于调试）
        self.log(f"  请求URL: {api_url}")
        #self.log(f"  请求体: {json.dumps(payload, ensure_ascii=False)[:300]}...")

        try:
            # 设置正确的Content-Type头
            headers = {
                "Content-Type": "application/json"
            }

            # 发送请求（流式接口直接返回音频）
            response = requests.post(api_url, json=payload, headers=headers, timeout=120)

            # 打印响应状态和内容（便于调试）
            self.log(f"  响应状态: {response.status_code} {response.reason}")
            self.log(f"  响应类型: {response.headers.get('Content-Type', 'unknown')}")

            # 如果请求失败，打印响应内容
            if not response.ok:
                try:
                    error_detail = response.json()
                    self.log(f"  错误详情: {json.dumps(error_detail, ensure_ascii=False)}")
                except:
                    self.log(f"  错误详情: {response.text[:500]}")
                response.raise_for_status()

            content_type = response.headers.get('Content-Type', '')

            # 如果直接返回音频二进制数据（流式接口）
            if 'audio' in content_type or 'octet-stream' in content_type or 'mpeg' in content_type:
                self.log(f"  ✓ 音频生成完成，大小: {len(response.content)} 字节")
                return response.content, 'audio'

            # 如果返回JSON（可能包含错误或其他信息）
            if 'application/json' in content_type:
                data = response.json()
                self.log(f"  响应数据: {json.dumps(data, ensure_ascii=False)[:300]}")

                # 检查是否有错误
                if 'error' in data or 'err' in data:
                    error_msg = data.get('error') or data.get('err') or data.get('message', 'Unknown error')
                    raise Exception(f"API返回错误: {error_msg}")

                # 如果包含音频URL
                if 'url' in data or 'audio_url' in data or 'download_url' in data:
                    audio_url = data.get('url') or data.get('audio_url') or data.get('download_url')
                    self.log(f"  从URL下载音频: {audio_url}")
                    return self._download_audio_from_url(audio_url)

                # 如果包含base64音频数据
                if 'audio' in data or 'data' in data:
                    return data, 'json'

                return data, 'json'

            # 其他格式直接返回
            self.log(f"  响应大小: {len(response.content)} 字节")
            return response.content, 'unknown'

        except requests.exceptions.RequestException as e:
            raise Exception(f"API请求失败: {e}")

    def _download_audio_from_url(self, audio_url):
        """从URL下载音频"""
        self.log(f"  正在下载音频: {audio_url}")
        resp = requests.get(audio_url, timeout=60)

        if not resp.ok:
            raise Exception(f"下载音频失败: {resp.status_code}")

        self.log(f"  ✓ 音频下载完成，大小: {len(resp.content)} 字节")
        return resp.content, 'audio'

    def process_audio_generation(self):
        """处理有声生成（后台线程）"""
        try:
            api_url = self.api_url_entry.get().strip()
            voice = self.voice_var.get()
            rate = self.rate_var.get()
            pitch = self.pitch_var.get()
            volume = self.volume_var.get()

            self.log(f"API地址: {api_url}")
            self.log(f"语音参数: voice={voice}, rate={rate}, pitch={pitch}, volume={volume}")

            # 根据输入模式获取文件列表
            mode = self.input_mode_var.get()
            if mode == "folder":
                # 文件夹模式
                self.log(f"正在扫描文件夹: {self.novel_folder}")
                chapter_files = self.get_chapter_files(self.novel_folder)
            else:
                # 多选文件模式
                chapter_files = [Path(f) for f in self.selected_files]
                self.log(f"使用多选文件模式，共 {len(chapter_files)} 个文件")

            # 按文件名排序
            chapter_files.sort(key=lambda x: x.name)

            if not chapter_files:
                self.log("错误: 文件夹中没有找到txt文件")
                return

            self.log(f"找到 {len(chapter_files)} 个章节文件")

            # 创建输出目录
            output_path = Path(self.audio_output_dir) if self.audio_output_dir else Path(self.novel_folder) / "audio"
            output_path.mkdir(parents=True, exist_ok=True)

            self.log(f"音频输出目录: {output_path}")

            # 处理每个章节
            success_count = 0
            fail_count = 0

            for i, chapter_file in enumerate(chapter_files, 1):
                # 检查停止状态
                if self.audio_stopped:
                    self.log("\n用户停止了生成任务")
                    break

                # 检查暂停状态
                while self.audio_paused and not self.audio_stopped:
                    self.root.after(100, lambda: None)
                    import time
                    time.sleep(0.1)

                # 再次检查是否被停止
                if self.audio_stopped:
                    self.log("\n用户停止了生成任务")
                    break

                try:
                    self.log(f"\n[{i}/{len(chapter_files)}] 正在处理: {chapter_file.name}")

                    # 读取章节内容
                    content = self.read_chapter_content(chapter_file)
                    content = content.strip()

                    if not content:
                        self.log(f"  跳过空文件: {chapter_file.name}")
                        continue

                    # 调用API生成音频
                    self.log(f"  正在调用API... (文本长度: {len(content)} 字符)")
                    result, result_type = self.call_tts_api(
                        content, api_url, voice, rate, pitch, volume
                    )

                    # 保存音频文件
                    audio_filename = chapter_file.stem + ".mp3"
                    audio_filepath = output_path / audio_filename

                    if result_type == 'audio':
                        with open(audio_filepath, 'wb') as f:
                            f.write(result)
                        self.log(f"  ✓ 已保存: {audio_filename}")
                        success_count += 1
                    elif result_type == 'json':
                        # 如果API返回JSON，可能包含音频数据的base64编码或URL
                        json_path = output_path / (chapter_file.stem + ".json")
                        with open(json_path, 'w', encoding='utf-8') as f:
                            json.dump(result, f, ensure_ascii=False, indent=2)
                        self.log(f"  ✓ 已保存JSON响应: {json_path.name}")
                        success_count += 1
                    else:
                        # 保存原始响应
                        with open(audio_filepath, 'wb') as f:
                            f.write(result)
                        self.log(f"  ✓ 已保存响应: {audio_filename}")
                        success_count += 1

                except Exception as e:
                    self.log(f"  ✗ 处理失败: {e}")
                    fail_count += 1
                    continue

            # 输出统计信息
            self.log(f"\n{'='*50}")
            if self.audio_stopped:
                self.log(f"生成已停止!")
            else:
                self.log(f"生成完成!")
            self.log(f"成功: {success_count}/{len(chapter_files)}")
            if fail_count > 0:
                self.log(f"失败: {fail_count}/{len(chapter_files)}")
            self.log(f"输出目录: {output_path}")
            self.log(f"{'='*50}")

        except Exception as e:
            self.log(f"\n✗ 生成出错: {e}")
        finally:
            self.audio_processing = False
            self.root.after(0, self.process_audio_done)


def main():
    root = tk.Tk()
    app = NovelCleanerGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
