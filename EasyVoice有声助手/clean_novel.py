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
import shutil
import os
from pathlib import Path
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
import tkinter as tk
from tkinter import ttk, filedialog, scrolledtext, messagebox

# 获取系统 CPU 核心数作为最大可用线程数
MAX_AVAILABLE_WORKERS = os.cpu_count() or 4
# 默认线程数（不超过 CPU 核心数）
DEFAULT_WORKERS = min(4, MAX_AVAILABLE_WORKERS)


class NovelCleanerGUI:
    """小说清理工具图形界面"""

    def __init__(self, root):
        self.root = root
        self.root.title("小说文本清理与切分工具")
        self.root.geometry("900x900")  # 增大窗口高度
        self.root.resizable(True, True)

        # 文本清理模式的变量
        self.input_file = None
        self.output_dir = None
        self.processing = False

        # 有声生成模式的变量
        self.novel_folder = None
        self.selected_files = []  # 多选的文件列表
        self.audio_processing = False
        self.audio_paused = False
        self.audio_stopped = False

        # 多线程标志
        self.use_multithreading = tk.BooleanVar(value=True)
        # 线程数选择（默认值为 CPU 核心数和4之间的较小值）
        self.worker_count = tk.IntVar(value=DEFAULT_WORKERS)

        # 日志文件锁（线程安全）
        self.log_lock = threading.Lock()

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
        """设置有声生成选项卡（在原基础上增加多线程复选框）"""
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
        self.audio_output_var = tk.StringVar()  # 绑定变量
        self.audio_output_entry = ttk.Entry(file_frame, textvariable=self.audio_output_var)
        self.audio_output_entry.grid(row=5, column=1, sticky=tk.EW, padx=5, pady=3)
        ttk.Button(file_frame, text="浏览...", width=8, command=self.select_audio_output_dir).grid(row=5, column=2, pady=3)

        # 配置列权重，让Entry所在列可以拉伸
        file_frame.columnconfigure(1, weight=1)

        # API配置区域
        api_frame = ttk.LabelFrame(scrollable_frame, text="API配置", padding="8")
        api_frame.pack(fill=tk.BOTH, expand=True, padx=5, pady=3)

        ttk.Label(api_frame, text="API地址:").grid(row=0, column=0, sticky=tk.W, pady=3)
        self.api_url_entry = ttk.Entry(api_frame)
        self.api_url_entry.insert(0, "http://127.0.0.1:3110/api/v1/tts/generateJson")
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

        # --- 多线程选项（放在 params_frame 后面，操作按钮上方）---
        # 创建一个新的框架，确保它独立且可见
        thread_frame = ttk.LabelFrame(scrollable_frame, text="处理加速", padding="5")
        thread_frame.pack(fill=tk.X, padx=5, pady=5)

        # 标题和最大线程数显示
        header_frame = ttk.Frame(thread_frame)
        header_frame.pack(fill=tk.X, pady=(0, 5))
        ttk.Label(header_frame, text="⚙️ 多线程加速选项", foreground="blue").pack(side=tk.LEFT)
        ttk.Label(header_frame, text=f"(系统最大可用线程: {MAX_AVAILABLE_WORKERS})", foreground="gray", font=("", 8)).pack(side=tk.RIGHT)

        # 多线程启用复选框和线程数选择
        control_frame = ttk.Frame(thread_frame)
        control_frame.pack(fill=tk.X, pady=5)

        self.multithread_cb = ttk.Checkbutton(
            control_frame,
            text="启用多线程加速",
            variable=self.use_multithreading,
            command=self.on_multithread_toggle
        )
        self.multithread_cb.pack(side=tk.LEFT, padx=(0, 15))

        # 线程数选择区域
        worker_frame = ttk.Frame(control_frame)
        worker_frame.pack(side=tk.LEFT)

        ttk.Label(worker_frame, text="线程数:").pack(side=tk.LEFT, padx=(0, 5))

        # 线程数下拉框
        worker_values = list(range(1, MAX_AVAILABLE_WORKERS + 1))
        self.worker_combo = ttk.Combobox(
            worker_frame,
            textvariable=self.worker_count,
            values=worker_values,
            width=5,
            state="readonly"
        )
        self.worker_combo.pack(side=tk.LEFT)
        self.worker_combo.bind("<<ComboboxSelected>>", self.on_worker_count_changed)

        # 当前线程数显示标签
        self.worker_label = ttk.Label(worker_frame, text=f"(当前: {self.worker_count.get()})", foreground="green", font=("", 9))
        self.worker_label.pack(side=tk.LEFT, padx=(5, 0))

        # 初始化时设置初始状态
        self.on_multithread_toggle()

        # 强制更新滚动区域（多次确保）
        scrollable_frame.update_idletasks()
        top_canvas.configure(scrollregion=top_canvas.bbox("all"))
        self.root.after(100, lambda: top_canvas.configure(scrollregion=top_canvas.bbox("all")))

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

        # 鼠标滚轮支持 - 绑定到所有子框架，确保滚轮事件能正确传递
        def _on_mousewheel(event):
            top_canvas.yview_scroll(int(-1*(event.delta/120)), "units")

        # 绑定到canvas和scrollable_frame，以及所有子框架
        top_canvas.bind("<MouseWheel>", _on_mousewheel)
        scrollable_frame.bind("<MouseWheel>", _on_mousewheel)

        # 递归绑定滚轮事件到所有子组件
        def bind_mousewheel(widget):
            try:
                widget.bind("<MouseWheel>", _on_mousewheel)
            except:
                pass
            for child in widget.winfo_children():
                bind_mousewheel(child)

        # 对所有配置框架应用滚轮绑定
        bind_mousewheel(file_frame)
        bind_mousewheel(api_frame)
        bind_mousewheel(params_frame)
        bind_mousewheel(thread_frame)

        # 初始化输入模式状态（默认文件夹模式，禁用多选文件）
        self.on_input_mode_changed()

    def log(self, message):
        """添加日志（同时写入文件和界面）"""
        timestamp = datetime.now().strftime('%H:%M:%S')
        log_line = f"[{timestamp}] {message}\n"

        # 界面显示
        self.log_text.insert(tk.END, log_line)
        self.log_text.see(tk.END)
        self.root.update_idletasks()

        # 写入日志文件
        try:
            # 确保 logs 目录存在
            log_dir = Path(__file__).parent / "logs"
            log_dir.mkdir(exist_ok=True)

            # 以当前日期命名的日志文件
            today = datetime.now().strftime('%Y%m%d')
            log_file = log_dir / f"{today}.log"

            with self.log_lock:
                with open(log_file, 'a', encoding='utf-8') as f:
                    f.write(log_line)
        except Exception as e:
            # 如果文件写入失败，只在界面提示（避免递归）
            self.log_text.insert(tk.END, f"[{timestamp}] 日志文件写入失败: {e}\n")
            self.log_text.see(tk.END)

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
        """检测章节标题模式（增强版）"""
        # 输出前20行用于调试（看看实际文本内容）
        lines = content.split('\n')[:20]
        self.log("文件前20行（原始格式）：")
        for i, line in enumerate(lines):
            self.log(f"{i+1}: {repr(line)}")  # repr 可以显示不可见字符

        # 更宽松的模式列表
        patterns = [
            (r'^\s*第\s*[零一二三四五六七八九十百千万0-9]+\s*[章回卷节集部篇].*$', "第X章"),
            (r'^\s*第\s*[0-9]+\s*[章回卷节集部篇].*$', "第X章(阿拉伯数字)"),
            (r'^\s*[零一二三四五六七八九十百千万0-9]+\s*、.*$', "数字、"),
            (r'^\s*Chapter\s+\d+.*$', "Chapter"),
            (r'^\s*卷\s*[零一二三四五六七八九十百千万0-9]+.*$', "卷X"),
            (r'^\s*(序言|前言|引言|楔子|尾声|后记|番外|目录|正文)$', "序章/番外"),
        ]

        best_pattern = None
        max_matches = 0
        best_name = ""

        for pattern, name in patterns:
            matches = len(re.findall(pattern, content, re.MULTILINE))
            self.log(f"  模式「{name}」匹配到 {matches} 个")
            if matches > max_matches:
                max_matches = matches
                best_pattern = pattern
                best_name = name

        if max_matches == 0:
            # 终极备用：只要包含“第”和“章”就认为是标题（谨慎使用）
            pattern = r'^.*第\s*[零一二三四五六七八九十百千万0-9]+\s*章.*$'
            matches = len(re.findall(pattern, content, re.MULTILINE))
            self.log(f"  终极备用模式匹配到 {matches} 个")
            if matches > 0:
                best_pattern = pattern
                best_name = "终极备用(包含'第'和'章')"
                max_matches = matches

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

    def on_multithread_toggle(self):
        """多线程复选框切换回调"""
        if self.use_multithreading.get():
            # 启用多线程：启用线程数选择
            self.worker_combo.config(state="readonly")
            self.worker_label.config(text=f"(当前: {self.worker_count.get()})", foreground="green")
        else:
            # 禁用多线程：禁用线程数选择
            self.worker_combo.config(state="disabled")
            self.worker_label.config(text="(当前: 1)", foreground="gray")

    def on_worker_count_changed(self, event=None):
        """线程数变化回调"""
        count = self.worker_count.get()
        if self.use_multithreading.get():
            self.worker_label.config(text=f"(当前: {count})", foreground="green")

    def on_input_mode_changed(self):
        """输入模式切换回调"""
        mode = self.input_mode_var.get()
        if mode == "folder":
            # 文件夹模式：启用文件夹选择，禁用文件选择
            self.folder_entry.config(state=tk.NORMAL)
            self.folder_btn.config(state=tk.NORMAL)
            self.files_entry.config(state=tk.DISABLED)
            self.files_btn.config(state=tk.DISABLED)
            # 如果已有选择的文件夹，更新文件数量显示
            if self.novel_folder:
                chapter_files = self.get_chapter_files(self.novel_folder)
                self.selected_files_label.config(
                    text=f"找到 {len(chapter_files)} 个txt文件",
                    foreground="green"
                )
        else:
            # 多选文件模式：禁用文件夹选择，启用文件选择
            self.folder_entry.config(state=tk.DISABLED)
            self.folder_btn.config(state=tk.DISABLED)
            self.files_entry.config(state=tk.NORMAL)
            self.files_btn.config(state=tk.NORMAL)
            # 清空文件夹模式的文件数量显示
            self.selected_files_label.config(
                text="",
                foreground="gray"
            )

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

            # 自动设置音频输出目录（跨平台兼容）
            if not self.audio_output_var.get() and len(folder_paths) == 1:
                folder_path = Path(list(folder_paths)[0])
                default_output = str(folder_path.parent / f"{folder_path.name}_audio")
                self.audio_output_var.set(default_output)

    def select_novel_folder(self):
        """选择小说文件夹（章节txt所在目录）"""
        dirname = filedialog.askdirectory(title="选择小说章节文件夹")
        if dirname:
            self.novel_folder = dirname
            self.folder_entry.delete(0, tk.END)
            self.folder_entry.insert(0, dirname)
            # 自动设置音频输出目录
            if not self.audio_output_var.get():
                default_output = str(Path(dirname) / "audio")
                self.audio_output_var.set(default_output)
            # 扫描并显示文件夹中的txt文件数量
            chapter_files = self.get_chapter_files(dirname)
            self.selected_files_label.config(
                text=f"找到 {len(chapter_files)} 个txt文件",
                foreground="green"
            )

    def select_audio_output_dir(self):
        """选择音频输出目录"""
        dirname = filedialog.askdirectory(title="选择音频输出目录")
        if dirname:
            self.audio_output_var.set(dirname)

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

        # 获取音频输出目录（从绑定的变量读取）
        audio_output_dir = self.audio_output_var.get().strip()
        if not audio_output_dir:
            self.log("错误: 请先选择或输入音频输出目录")
            return

        self.audio_processing = True
        self.audio_paused = False
        self.audio_stopped = False
        self.audio_process_btn.config(state=tk.DISABLED)
        self.audio_pause_btn.config(state=tk.NORMAL)
        self.audio_stop_btn.config(state=tk.NORMAL)
        self.audio_progress.start()

        # 在后台线程处理
        thread = threading.Thread(target=self.process_audio_generation, args=(audio_output_dir,))
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

    def split_long_text(self, text, max_len=3000):
        """
        将长文本按段落分割成多个短文本，每段不超过 max_len 字符。
        如果段落本身超过 max_len，则按句子分割。
        """
        paragraphs = text.split('\n')
        chunks = []
        current_chunk = ""

        for para in paragraphs:
            # 如果当前段落加上当前块超过最大长度，先保存当前块
            if len(current_chunk) + len(para) + 1 > max_len and current_chunk:
                chunks.append(current_chunk.strip())
                current_chunk = ""

            # 如果段落本身超过 max_len，则按句子进一步分割
            if len(para) > max_len:
                # 简单按句号、感叹号、问号分割
                sentences = re.split(r'([。！？])', para)
                # re.split 会保留分隔符，需要合并
                temp_sentences = []
                for i in range(0, len(sentences)-1, 2):
                    temp_sentences.append(sentences[i] + sentences[i+1])
                if len(sentences) % 2 == 1:
                    temp_sentences.append(sentences[-1])

                for sent in temp_sentences:
                    if len(current_chunk) + len(sent) + 1 > max_len and current_chunk:
                        chunks.append(current_chunk.strip())
                        current_chunk = ""
                    current_chunk += sent + "\n"
            else:
                # 正常段落
                if current_chunk:
                    current_chunk += "\n" + para
                else:
                    current_chunk = para

        if current_chunk:
            chunks.append(current_chunk.strip())

        return chunks

    def call_tts_api(self, text, api_url, voice, rate, pitch, volume, retries=3):
        """调用TTS API生成音频（带重试和超时）"""
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
        headers = {"Content-Type": "application/json"}

        for attempt in range(1, retries + 1):
            try:
                self.log(f"  尝试第 {attempt} 次请求...")
                # 增加超时到 300 秒（5分钟）
                response = requests.post(api_url, json=payload, headers=headers, timeout=300)

                self.log(f"  响应状态: {response.status_code} {response.reason}")
                self.log(f"  响应类型: {response.headers.get('Content-Type', 'unknown')}")

                if not response.ok:
                    # 尝试解析错误详情
                    try:
                        error_detail = response.json()
                        self.log(f"  错误详情: {json.dumps(error_detail, ensure_ascii=False)}")
                    except:
                        self.log(f"  错误详情: {response.text[:500]}")
                    # 如果不是最后一次尝试，则等待后重试
                    if attempt < retries:
                        wait = 2 ** attempt  # 指数退避：2,4,8秒...
                        self.log(f"  等待 {wait} 秒后重试...")
                        time.sleep(wait)
                        continue
                    else:
                        response.raise_for_status()

                content_type = response.headers.get('Content-Type', '')

                # 成功处理返回数据
                if 'audio' in content_type or 'octet-stream' in content_type or 'mpeg' in content_type:
                    self.log(f"  ✓ 音频生成完成，大小: {len(response.content)} 字节")
                    return response.content, 'audio'

                if 'application/json' in content_type:
                    data = response.json()
                    self.log(f"  响应数据: {json.dumps(data, ensure_ascii=False)[:300]}")
                    if 'error' in data or 'err' in data:
                        error_msg = data.get('error') or data.get('err') or data.get('message', 'Unknown error')
                        raise Exception(f"API返回错误: {error_msg}")
                    if 'url' in data or 'audio_url' in data or 'download_url' in data:
                        audio_url = data.get('url') or data.get('audio_url') or data.get('download_url')
                        self.log(f"  从URL下载音频: {audio_url}")
                        return self._download_audio_from_url(audio_url)
                    if 'audio' in data or 'data' in data:
                        return data, 'json'
                    return data, 'json'

                self.log(f"  响应大小: {len(response.content)} 字节")
                return response.content, 'unknown'

            except requests.exceptions.RequestException as e:
                self.log(f"  请求异常: {e}")
                if attempt < retries:
                    wait = 2 ** attempt
                    self.log(f"  等待 {wait} 秒后重试...")
                    time.sleep(wait)
                else:
                    raise Exception(f"API请求失败，已重试{retries}次: {e}")

        # 不应该执行到这里
        raise Exception("未知错误")

    def _download_audio_from_url(self, audio_url):
        """从URL下载音频"""
        self.log(f"  正在下载音频: {audio_url}")
        resp = requests.get(audio_url, timeout=60)

        if not resp.ok:
            raise Exception(f"下载音频失败: {resp.status_code}")

        self.log(f"  ✓ 音频下载完成，大小: {len(resp.content)} 字节")
        return resp.content, 'audio'

    # ---------- 清理 EasyVoice 临时文件（彻底清空目录） ----------
    def clean_easyvoice_cache(self, cache_dir):
        """
        彻底清空 EasyVoice 缓存目录（删除所有文件，但保留目录本身）。
        如果文件被占用则跳过（记录日志）。
        """
        if not cache_dir.exists():
            return

        deleted_count = 0
        failed_count = 0
        for item in cache_dir.iterdir():
            try:
                if item.is_file():
                    item.unlink()
                    deleted_count += 1
                elif item.is_dir():
                    shutil.rmtree(item)
                    deleted_count += 1
            except (PermissionError, OSError) as e:
                failed_count += 1
                self.log(f"  无法删除 {item.name}：{e}")

        if deleted_count > 0 or failed_count > 0:
            self.log(f"清理缓存：成功删除 {deleted_count} 项，失败 {failed_count} 项")

    # ---------- 处理单个章节（供多线程调用）----------
    def process_one_chapter(self, chapter_file, output_path, api_url, voice, rate, pitch, volume, stop_flag):
        """
        处理单个章节：生成分段临时音频，合并，删除临时文件。
        返回 (success, chapter_name, error_message)
        """
        cache_dir = None
        temp_files = []
        try:
            # 如果停止标志被设置，则跳过
            if stop_flag and stop_flag.is_set():
                return (False, chapter_file.name, "已停止")

            # 读取章节内容
            content = self.read_chapter_content(chapter_file)
            content = content.strip()
            if not content:
                return (False, chapter_file.name, "空文件")

            # 分割长文本
            text_chunks = self.split_long_text(content)

            # 定义并确保缓存目录存在（跨平台兼容）
            cache_dir = Path(__file__).parent / "audio"
            cache_dir.mkdir(parents=True, exist_ok=True)

            # 生成每个分段的音频
            for chunk_idx, chunk in enumerate(text_chunks, 1):
                if stop_flag and stop_flag.is_set():
                    # 如果停止，则删除已生成的临时文件
                    for f in temp_files:
                        try:
                            f.unlink()
                        except:
                            pass
                    return (False, chapter_file.name, "已停止")

                result, result_type = self.call_tts_api(
                    chunk, api_url, voice, rate, pitch, volume
                )
                # 保存到临时文件（使用缓存目录）
                temp_filename = f"{chapter_file.stem}_part{chunk_idx}.mp3"
                temp_path = cache_dir / temp_filename
                with open(temp_path, 'wb') as f:
                    f.write(result)
                temp_files.append(temp_path)

            # 合并所有分段为完整章节 MP3
            final_filename = chapter_file.stem + ".mp3"
            final_path = output_path / final_filename
            with open(final_path, 'wb') as out_f:
                for temp in temp_files:
                    # 确保临时文件存在再读取
                    if temp.exists():
                        with open(temp, 'rb') as in_f:
                            shutil.copyfileobj(in_f, out_f)
                    else:
                        raise FileNotFoundError(f"临时文件不存在: {temp}")

            return (True, chapter_file.name, "")
        except Exception as e:
            return (False, chapter_file.name, str(e))
        finally:
            # 无论成功失败，都清理此章节的临时文件
            for temp in temp_files:
                try:
                    if temp.exists():
                        temp.unlink()
                except:
                    pass

    # ---------- 修改 process_audio_generation 方法 ----------
    def process_audio_generation(self, audio_output_dir):
        """处理有声生成（后台线程）- 支持多线程"""
        try:
            api_url = self.api_url_entry.get().strip()
            voice = self.voice_var.get()
            rate = self.rate_var.get()
            pitch = self.pitch_var.get()
            volume = self.volume_var.get()

            self.log(f"API地址: {api_url}")
            self.log(f"语音参数: voice={voice}, rate={rate}, pitch={pitch}, volume={volume}")

            # 定义 EasyVoice 缓存目录（脚本所在目录下的 audio 文件夹）
            easyvoice_cache = Path(__file__).parent / "audio"
            # 开始前先彻底清理一次
            self.clean_easyvoice_cache(easyvoice_cache)

            # 根据输入模式获取文件列表
            mode = self.input_mode_var.get()
            if mode == "folder":
                self.log(f"正在扫描文件夹: {self.novel_folder}")
                chapter_files = self.get_chapter_files(self.novel_folder)
            else:
                chapter_files = [Path(f) for f in self.selected_files]
                self.log(f"使用多选文件模式，共 {len(chapter_files)} 个文件")

            # 按文件名排序
            chapter_files.sort(key=lambda x: x.name)

            if not chapter_files:
                self.log("错误: 文件夹中没有找到txt文件")
                return

            self.log(f"找到 {len(chapter_files)} 个章节文件")

            # 创建输出目录
            output_path = Path(audio_output_dir)
            output_path.mkdir(parents=True, exist_ok=True)

            self.log(f"音频输出目录: {output_path}")

            # 处理方式选择
            if self.use_multithreading.get():
                # 多线程模式
                worker_count = self.worker_count.get()
                self.log(f"启用多线程加速，线程数: {worker_count}")
                # 禁用暂停按钮
                self.root.after(0, lambda: self.audio_pause_btn.config(state=tk.DISABLED))
                # 创建一个停止事件
                stop_event = threading.Event()

                success_count = 0
                fail_count = 0
                failed_files = []

                with ThreadPoolExecutor(max_workers=worker_count) as executor:
                    # 提交所有任务
                    future_to_file = {}
                    for cf in chapter_files:
                        future = executor.submit(
                            self.process_one_chapter,
                            cf, output_path, api_url, voice, rate, pitch, volume,
                            stop_event
                        )
                        future_to_file[future] = cf

                    # 实时处理完成结果
                    for future in as_completed(future_to_file):
                        if self.audio_stopped:
                            stop_event.set()
                            break
                        success, name, err = future.result()
                        if success:
                            success_count += 1
                            self.log(f"  ✓ 完成: {name}")
                        else:
                            fail_count += 1
                            failed_files.append(name)
                            self.log(f"  ✗ 失败: {name} - {err}")

                    # 如果被停止，取消剩余任务（但已经提交的无法取消，只能等待）
                    if self.audio_stopped:
                        self.log("用户停止了生成任务")

                # 统计信息
                self.log(f"\n{'='*50}")
                self.log(f"生成完成! 成功: {success_count}/{len(chapter_files)}")
                if fail_count > 0:
                    self.log(f"失败: {fail_count}")
                    self.log("失败文件列表:")
                    for fname in failed_files:
                        self.log(f"  - {fname}")
                self.log(f"输出目录: {output_path}")
                self.log(f"{'='*50}")

            else:
                # 单线程模式（保留原逻辑，但改为合并临时文件方式）
                self.log("单线程模式")
                # 复用原有的串行处理逻辑，但改为新的处理函数
                success_count = 0
                fail_count = 0
                failed_files = []

                for i, chapter_file in enumerate(chapter_files, 1):
                    # 检查停止状态
                    if self.audio_stopped:
                        self.log("\n用户停止了生成任务")
                        break

                    # 检查暂停状态
                    while self.audio_paused and not self.audio_stopped:
                        self.root.after(100, lambda: None)
                        time.sleep(0.1)

                    if self.audio_stopped:
                        break

                    self.log(f"\n[{i}/{len(chapter_files)}] 正在处理: {chapter_file.name}")

                    success, name, err = self.process_one_chapter(
                        chapter_file, output_path, api_url, voice, rate, pitch, volume,
                        None  # 无停止事件
                    )
                    if success:
                        success_count += 1
                        self.log(f"  ✓ 完成: {name}")
                    else:
                        fail_count += 1
                        failed_files.append(name)
                        self.log(f"  ✗ 失败: {name} - {err}")

                    # 每处理10个文件，休息30秒
                    if i % 10 == 0:
                        self.log(f"已处理 {i} 个文件，休息30秒让服务恢复...")
                        time.sleep(30)

                # 输出统计信息
                self.log(f"\n{'='*50}")
                if self.audio_stopped:
                    self.log(f"生成已停止!")
                else:
                    self.log(f"生成完成!")
                self.log(f"成功: {success_count}/{len(chapter_files)}")
                if fail_count > 0:
                    self.log(f"失败: {fail_count}")
                    self.log("失败文件列表:")
                    for fname in failed_files:
                        self.log(f"  - {fname}")
                self.log(f"输出目录: {output_path}")
                self.log(f"{'='*50}")

        except Exception as e:
            self.log(f"\n✗ 生成出错: {e}")
        finally:
            # 最后再彻底清理一次缓存目录
            easyvoice_cache = Path(__file__).parent / "audio"
            self.clean_easyvoice_cache(easyvoice_cache)
            self.audio_processing = False
            self.root.after(0, self.process_audio_done)


def main():
    root = tk.Tk()
    app = NovelCleanerGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()