#!/usr/bin/env python3
"""LocalShift offline format helpers. No subprocess, network, installation or shell calls."""
import csv, ctypes, ctypes.util, gzip, html, io, json, os, pathlib, plistlib, posixpath, re, shutil, stat, sys, tarfile, uuid, zipfile
import xml.etree.ElementTree as ET
from decimal import Decimal
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit

MAX_ENTRIES=20000
MAX_FILE=512*1024*1024
MAX_TOTAL=2*1024*1024*1024
W='http://schemas.openxmlformats.org/wordprocessingml/2006/main'
R='http://schemas.openxmlformats.org/officeDocument/2006/relationships'
A='http://schemas.openxmlformats.org/drawingml/2006/main'
P='http://schemas.openxmlformats.org/presentationml/2006/main'
S='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
REL='http://schemas.openxmlformats.org/package/2006/relationships'

def fail(message): raise ValueError(message)
def xml_text(data):
    # Decode before checking XML constructs so UTF-16 cannot hide DTD/entities.
    # Feed the same Unicode text to both XML validation and the EPUB text parser.
    if isinstance(data,str): text=data.lstrip('\ufeff')
    elif data.startswith((b'\xff\xfe',b'\xfe\xff')): text=data.decode('utf-16')
    elif data.startswith(b'<\x00'): text=data.decode('utf-16-le')
    elif data.startswith(b'\x00<'): text=data.decode('utf-16-be')
    else:
        declaration=re.match(br'\s*<\?xml\b[^>]*\bencoding\s*=\s*[\"\']([A-Za-z0-9._-]+)[\"\']',data[:512],re.I)
        encoding=declaration.group(1).decode('ascii') if declaration else 'utf-8-sig'
        text=data.decode(encoding)
    if '\x00' in text: fail('XML 含不支持的编码或空字符。')
    if re.search(r'<!\s*(DOCTYPE|ENTITY)',text,re.I): fail('拒绝 XML 的外部实体或 DTD。')
    return text

def xml(data):
    text=xml_text(data)
    # The bytes have already been decoded. Remove the original byte-encoding
    # declaration instead of relabelling UTF-16 bytes as UTF-8.
    text=re.sub(r'^\s*<\?xml\b.*?\?>','',text,count=1,flags=re.S)
    return ET.fromstring(text)
def esc(s): return html.escape(re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\ud800-\udfff]", "", str(s)),quote=True)
def txt(e): return ''.join(e.itertext())
def local(e): return e.tag.split('}')[-1]
def safe_name(name):
    if not isinstance(name,str) or not name or '\x00' in name or '\\' in name or name.startswith('/') or re.match(r'^[A-Za-z]:',name): fail('归档含绝对路径或无效路径。')
    parts=name.split('/')
    if '..' in parts: fail('归档含路径穿越。')
    clean=posixpath.normpath(name)
    if clean in ('','.') or clean.startswith('../'): return None
    return clean

def zip_members(z):
    infos=z.infolist()
    if len(infos)>MAX_ENTRIES: fail('归档条目数超过安全上限。')
    total=0
    for i in infos:
        safe_name(i.filename)
        mode=(i.external_attr>>16)&0xffff
        if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0,stat.S_IFREG,stat.S_IFDIR)) or (i.external_attr&0x400): fail('归档含链接或特殊文件。')
        if i.flag_bits&1: fail('不支持加密归档。')
        if i.file_size>MAX_FILE: fail('归档单文件超过安全上限。')
        total+=i.file_size
        if total>MAX_TOTAL: fail('归档解压大小超过安全上限。')
    return infos

def copy_stream(src,dst,limit=MAX_FILE):
    size=0
    with open(dst,'xb') as out:
        while True:
            chunk=src.read(1024*1024)
            if not chunk: break
            size+=len(chunk)
            if size>limit: fail('文件超过安全上限。')
            out.write(chunk)
    return size

def target(root,name):
    name=safe_name(name)
    if name is None: return None
    root=os.path.realpath(root); dest=os.path.join(root,*name.split('/'))
    if os.path.commonpath([root,os.path.realpath(dest)])!=root: fail('归档路径越界。')
    os.makedirs(os.path.dirname(dest),exist_ok=True)
    return dest

def libarchive_extract(source,dest):
    # libarchive performs decompression only; LocalShift validates each entry and writes bytes itself.
    path=ctypes.util.find_library('archive') or '/usr/lib/libarchive.dylib'
    lib=ctypes.CDLL(path)
    def fn(name,result,args):
        f=getattr(lib,name);f.restype=result;f.argtypes=args;return f
    new=fn('archive_read_new',ctypes.c_void_p,[])
    allfilter=fn('archive_read_support_filter_all',ctypes.c_int,[ctypes.c_void_p])
    allformat=fn('archive_read_support_format_all',ctypes.c_int,[ctypes.c_void_p])
    op=fn('archive_read_open_filename',ctypes.c_int,[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_size_t])
    nex=fn('archive_read_next_header',ctypes.c_int,[ctypes.c_void_p,ctypes.POINTER(ctypes.c_void_p)])
    pathname=fn('archive_entry_pathname',ctypes.c_char_p,[ctypes.c_void_p])
    typ=fn('archive_entry_filetype',ctypes.c_uint,[ctypes.c_void_p])
    sz=fn('archive_entry_size',ctypes.c_longlong,[ctypes.c_void_p])
    symlink=fn('archive_entry_symlink',ctypes.c_char_p,[ctypes.c_void_p])
    hardlink=fn('archive_entry_hardlink',ctypes.c_char_p,[ctypes.c_void_p])
    read=fn('archive_read_data',ctypes.c_ssize_t,[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t])
    error=fn('archive_error_string',ctypes.c_char_p,[ctypes.c_void_p])
    free=fn('archive_read_free',ctypes.c_int,[ctypes.c_void_p])
    ar=new();allfilter(ar);allformat(ar)
    def err(): return (error(ar) or b'libarchive error').decode('utf8','replace')
    try:
        if op(ar,os.fsencode(source),65536)<0: fail(err())
        count=0;total=0;entry=ctypes.c_void_p();buffer=ctypes.create_string_buffer(65536)
        while True:
            status=nex(ar,ctypes.byref(entry))
            if status==1: break
            if status<0: fail(err())
            count+=1
            if count>MAX_ENTRIES: fail('归档条目数超过安全上限。')
            name=(pathname(entry) or b'').decode('utf8','strict');kind=typ(entry)
            if symlink(entry) or hardlink(entry) or kind not in (stat.S_IFREG,stat.S_IFDIR): fail('归档含链接或特殊文件。')
            if sz(entry)>MAX_FILE: fail('归档单文件超过安全上限。')
            out=target(dest,name)
            if out is None: continue
            if kind==stat.S_IFDIR: os.makedirs(out,exist_ok=True);continue
            filetotal=0
            with open(out,'xb') as f:
                while True:
                    n=read(ar,buffer,len(buffer))
                    if n<0: fail(err())
                    if n==0: break
                    total+=n;filetotal+=n
                    if total>MAX_TOTAL or filetotal>MAX_FILE: fail('归档解压大小超过安全上限。')
                    f.write(buffer.raw[:n])
    finally: free(ar)

def extract(source,dest):
    if os.path.islink(source): fail('归档输入不能是符号链接。')
    os.makedirs(dest,exist_ok=True)
    if zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as z:
            infos=zip_members(z)
            for i in infos:
                out=target(dest,i.filename)
                if out is None: continue
                if i.is_dir(): os.makedirs(out,exist_ok=True)
                else:
                    with z.open(i) as f: copy_stream(f,out)
    elif tarfile.is_tarfile(source):
        with tarfile.open(source,'r:*') as t:
            count=0;total=0
            for i in t:
                count+=1;total+=i.size
                if count>MAX_ENTRIES or total>MAX_TOTAL or i.size>MAX_FILE: fail('归档大小超过安全上限。')
                if not (i.isfile() or i.isdir()): fail('归档含链接或特殊文件。')
                out=target(dest,i.name)
                if out is None: continue
                if i.isdir(): os.makedirs(out,exist_ok=True)
                else:
                    with t.extractfile(i) as f: copy_stream(f,out)
    elif pathlib.Path(source).suffix.lower() in ('.gz','.gzip'):
        name=pathlib.Path(source).stem or 'content'
        with gzip.open(source,'rb') as f: copy_stream(f,target(dest,name))
    else: libarchive_extract(source,dest)
    if not os.listdir(dest): fail('归档没有可提取内容。')

def checked_tree(root):
    count=0;total=0
    for base,dirs,files in os.walk(root,followlinks=False):
        for name in sorted(dirs+files):
            path=os.path.join(base,name);s=os.lstat(path)
            if stat.S_ISLNK(s.st_mode) or not (stat.S_ISDIR(s.st_mode) or stat.S_ISREG(s.st_mode)) or (stat.S_ISREG(s.st_mode) and s.st_nlink>1): fail('文件夹含链接或特殊文件。')
            count+=1;total+=s.st_size if stat.S_ISREG(s.st_mode) else 0
            if count>MAX_ENTRIES or total>MAX_TOTAL or s.st_size>MAX_FILE: fail('归档大小超过安全上限。')
            yield path,os.path.relpath(path,root)

def archive(source,output,kind,temp):
    if os.path.isdir(source):
        if os.path.islink(source): fail('不能归档符号链接。')
        root=source
    else: root=temp;extract(source,root)
    entries=list(checked_tree(root))
    if os.path.isdir(source):
        prefix=os.path.basename(os.path.normpath(source))
        entries=[(root,prefix)]+[(path,posixpath.join(prefix,name)) for path,name in entries]
    if kind=='zip':
        with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
            for path,name in entries: z.write(path,name)
    elif kind in ('tar','gz'):
        with tarfile.open(output,'w:gz' if kind=='gz' else 'w',format=tarfile.PAX_FORMAT,dereference=False) as t:
            for path,name in entries: t.add(path,arcname=name,recursive=False)
    else: fail('不支持的归档输出格式。')

class TextHTML(HTMLParser):
    def __init__(self): super().__init__(convert_charrefs=True);self.parts=[];self.skip=0
    def handle_starttag(self,t,attrs):
        if t in ('script','style'): self.skip+=1
        if t in ('p','div','br','tr','li','h1','h2','h3','section'): self.parts.append('\n')
        if t in ('td','th'): self.parts.append('\t')
    def handle_endtag(self,t):
        if t in ('script','style'): self.skip=max(0,self.skip-1)
        if t in ('p','div','tr','li','h1','h2','h3'): self.parts.append('\n')
    def handle_data(self,d):
        if not self.skip: self.parts.append(d)
    def text(self): return re.sub('\n[ \t]*\n+','\n\n',''.join(self.parts)).strip()

def text_model(text,title):
    lines=text.replace('\r\n','\n').replace('\r','\n').split('\n')
    return {'title':title,'pages':[{'width':612,'height':792,'blocks':[{'text':line,'x':48,'y':48+i*16,'width':516,'height':16,'fontSize':12} for i,line in enumerate(lines)]}]}

def docx_children(parent,wanted):
    """Yield visible block/row/cell children in source order through Word wrappers."""
    for child in parent:
        kind=local(child)
        if kind in wanted: yield child
        elif kind=='sdt':
            content=child.find('{%s}sdtContent'%W)
            if content is not None: yield from docx_children(content,wanted)
        elif kind in ('sdtContent','customXml','ins'):
            yield from docx_children(child,wanted)

def docx_paragraph_text(paragraph):
    return ''.join('\t' if local(n)=='tab' else '\n' if local(n) in ('br','cr') else n.text or ''
                   for n in paragraph.iter() if local(n) in ('t','tab','br','cr'))

def docx_table_rows(table):
    rows=[]
    for row in docx_children(table,{'tr'}):
        cells=[]
        for cell in docx_children(row,{'tc'}):
            blocks=[]
            for block in docx_children(cell,{'p','tbl'}):
                if local(block)=='p': blocks.append(docx_paragraph_text(block))
                else: blocks.extend('\t'.join(values) for values in docx_table_rows(block))
            cells.append('\n'.join(blocks))
        rows.append(cells)
    return rows

def read_docx(path):
    with zipfile.ZipFile(path) as z:
        zip_members(z);root=xml(z.read('word/document.xml'))
        body=root.find('{%s}body'%W);paragraphs=[];tables=[]
        if body is None: fail('DOCX 缺少可读取的正文。')
        for item in docx_children(body,{'p','tbl'}):
            if local(item)=='p': paragraphs.append(docx_paragraph_text(item))
            else:
                rows=docx_table_rows(item)
                tables.append(rows);paragraphs.extend('\t'.join(r) for r in rows)
        model=text_model('\n'.join(paragraphs),pathlib.Path(path).stem);model['tables']=tables;return model

def safe_epub_reference(base,href):
    p=urlsplit(href)
    if p.scheme or p.netloc or p.path.startswith('/') or '\\' in p.path: fail('EPUB 含外部或绝对资源引用。')
    decoded=unquote(p.path)
    joined=posixpath.normpath(posixpath.join(base,decoded))
    if joined.startswith('../') or joined=='..': fail('EPUB 资源路径越界。')
    safe_name(joined);return joined

def read_epub(path):
    with zipfile.ZipFile(path) as z:
        zip_members(z)
        if z.read('mimetype').strip()!=b'application/epub+zip': fail('无效 EPUB mimetype。')
        container=xml(z.read('META-INF/container.xml'))
        full=next((e.attrib.get('full-path','') for e in container.iter() if local(e)=='rootfile'),'')
        opf=safe_epub_reference('',full);root=xml(z.read(opf));base=posixpath.dirname(opf)
        manifest={e.attrib['id']:safe_epub_reference(base,e.attrib.get('href','')) for e in root.iter() if local(e)=='item'}
        order=[manifest[e.attrib['idref']] for e in root.iter() if local(e)=='itemref' and e.attrib.get('idref') in manifest]
        if not order: fail('EPUB 没有可阅读章节。')
        chunks=[]
        for name in order:
            chapter=xml_text(z.read(name));page=xml(chapter)
            for node in page.iter():
                if local(node).lower() in ('script','iframe','object','embed'): fail('EPUB 含可执行内容。')
                for k,v in node.attrib.items():
                    if k.split('}')[-1] in ('src','href','poster'): safe_epub_reference(posixpath.dirname(name),v)
                    if k.lower().startswith('on'): fail('EPUB 含可执行事件。')
                    if k=='style' and re.search(r'url\s*\(|@import',v,re.I): fail('EPUB 内联样式含资源引用。')
            parser=TextHTML();parser.feed(chapter);chunks.append(parser.text())
        return text_model('\n\n'.join(chunks),pathlib.Path(path).stem)

def markdown_model(text,title):
    m=text_model(text,title);blocks=[];fenced=False
    for raw in text.splitlines():
        if raw.lstrip().startswith('```') or raw.lstrip().startswith('~~~'):
            fenced=not fenced;continue
        line=raw;level=0
        if not fenced:
            heading=re.match(r'^ {0,3}(#{1,6})\s+(.+?)(?:\s+#+)?$',line)
            if heading: level=len(heading.group(1));line=heading.group(2)
            line=re.sub(r'!\[([^]]*)\]\([^)]*\)',r'\1',line)
            line=re.sub(r'\[([^]]+)\]\([^)]*\)',r'\1',line)
            line=re.sub(r'(\*\*|__)(.+?)\1',r'\2',line)
            line=re.sub(r'`([^`]+)`',r'\1',line)
            line=re.sub(r'^\s*[-*+]\s+','• ',line)
            line=re.sub(r'^\s*>\s?','',line)
        blocks.append({'text':line,'level':level,'x':48,'y':48+len(blocks)*18,'width':516,'height':18,'fontSize':max(12,28-level*3) if level else 12})
    m['pages'][0]['blocks']=blocks;return m

def read_model(path):
    ext=pathlib.Path(path).suffix.lower()
    if ext=='.json': return json.load(open(path,encoding='utf8'))
    if ext=='.docx': return read_docx(path)
    if ext=='.epub': return read_epub(path)
    if ext in ('.csv','.tsv'):
        data=open(path,encoding='utf-8-sig').read();rows=list(csv.reader(io.StringIO(data),delimiter='\t' if ext=='.tsv' else ',',strict=True))
        m=text_model('\n'.join('\t'.join(r) for r in rows),pathlib.Path(path).stem);m['tables']=[rows];return m
    if ext=='.textclipping':
        with open(path,'rb') as f: data=f.read()
        try:
            d=plistlib.loads(data)
            text=d.get('UTI-Data',{}).get('public.utf8-plain-text') or d.get('public.utf8-plain-text') or d.get('Text') or d.get('text')
            if isinstance(text,bytes): text=text.decode('utf8')
            if not isinstance(text,str): fail('剪报没有可读取的 UTF-8 文本。')
        except plistlib.InvalidFileException: text=data.decode('utf8')
    else:
        data=open(path,'rb').read()
        try: text=data.decode('utf-8-sig')
        except UnicodeDecodeError: text=data.decode('utf-16')
        if ext in ('.html','.htm'):
            p=TextHTML();p.feed(text);text=p.text()
    if ext in ('.md','.markdown'): return markdown_model(text,pathlib.Path(path).stem)
    return text_model(text,pathlib.Path(path).stem)

def paragraphs(m):
    return [b.get('text','') for p in m.get('pages',[]) for b in p.get('blocks',[])]
def rows_for_page(page):
    if page.get('rows'): return page['rows']
    blocks=page.get('blocks',[]);rows=[]
    # Real PDF coordinates group fragments on the same baseline into editable cells.
    groups=[]
    for b in sorted(blocks,key=lambda b:(round(float(b.get('y',0))/4),float(b.get('x',0)))):
        y=float(b.get('y',0))
        if groups and abs(groups[-1][0]-y)<4: groups[-1][1].append(b)
        else: groups.append((y,[b]))
    for _,bs in groups:
        if len(bs)>1: rows.append([b.get('text','') for b in bs])
        else: rows.append(re.split(r'\t| {2,}|\s*\|\s*',bs[0].get('text','')))
    return rows or [['']]
def writezip(path,parts,stored=()):
    with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
        for name,data in parts.items(): z.writestr(name,data,compress_type=zipfile.ZIP_STORED if name in stored else zipfile.ZIP_DEFLATED)
def relationships(entries): return '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="'+REL+'">'+''.join('<Relationship Id="'+esc(i)+'" Type="'+esc(t)+'" Target="'+esc(p)+'"/>' for i,t,p in entries)+'</Relationships>'
def contenttypes(overrides):
    return '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'+''.join('<Override PartName="/'+esc(n)+'" ContentType="'+esc(t)+'"/>' for n,t in overrides)+'</Types>'
def wparagraph(s,level=0):
    runs=[]
    for i,line in enumerate(str(s).split('\n')):
        if i: runs.append('<w:r><w:br/></w:r>')
        for j,part in enumerate(line.split('\t')):
            if j: runs.append('<w:r><w:tab/></w:r>')
            runs.append('<w:r><w:t xml:space="preserve">'+esc(part)+'</w:t></w:r>')
    if level:
        size=max(24,56-int(level)*6)
        runs=['<w:r><w:rPr><w:b/><w:sz w:val="'+str(size)+'"/></w:rPr><w:t>'+esc(s)+'</w:t></w:r>']
        return '<w:p><w:pPr><w:outlineLvl w:val="'+str(min(8,int(level)-1))+'"/></w:pPr>'+''.join(runs)+'</w:p>'
    return '<w:p>'+''.join(runs)+'</w:p>'
def write_docx(m,path):
    body=[]
    for i,page in enumerate(m.get('pages',[])):
        if i: body.append('<w:p><w:r><w:br w:type="page"/></w:r></w:p>')
        body.extend(wparagraph(b.get('text',''),b.get('level',0)) for b in page.get('blocks',[]))
    # Tables use actual table cells, in addition to the page text when reconstructed from PDF.
    for table in m.get('tables',[]):
        body.append('<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>'+''.join('<w:tr>'+''.join('<w:tc>'+wparagraph(c)+'</w:tc>' for c in row)+'</w:tr>' for row in table)+'</w:tbl>')
    body.append('<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="960" w:right="960" w:bottom="960" w:left="960"/></w:sectPr>')
    parts={'[Content_Types].xml':contenttypes([('word/document.xml','application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml')]),'_rels/.rels':relationships([('rId1',R+'/officeDocument','word/document.xml')]),'word/document.xml':'<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="'+W+'"><w:body>'+''.join(body)+'</w:body></w:document>'}
    writezip(path,parts)
def spreadsheet_number(value):
    # Excel numbers have at most 15 significant decimal digits. Keep higher
    # precision values as text so opening or exporting the workbook cannot round
    # the user's original digits. Leading-zero identifiers remain text too.
    if not re.fullmatch(r'-?(?:0|[1-9][0-9]{0,14})(?:\.[0-9]+)?',value): return False
    number=Decimal(value);digits=list(number.as_tuple().digits)
    while len(digits)>1 and digits[-1]==0: digits.pop()
    return len(digits)<=15 and (not number or -307<=number.adjusted()<=307)

def write_xlsx(m,path):
    import math,unicodedata
    def display_width(value): return sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in value)
    pages=m.get('pages',[]) or [{}];parts={};over=[('xl/workbook.xml','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml')];sheets=[];rels=[]
    for n,page in enumerate(pages,1):
        rows=m.get('tables',[None])[0] if len(pages)==1 and m.get('tables') else rows_for_page(page)
        # Only helper-generated workbooks receive this print layout.
        count=max((len(row) for row in rows),default=0)
        widths=[max(12,min(60,max((display_width(line) for row in rows if ci<len(row) for line in str(row[ci]).splitlines()),default=0)+3)) for ci in range(count)]
        columns=''.join('<col min="'+str(i+1)+'" max="'+str(i+1)+'" width="'+str(width)+'" customWidth="1"/>' for i,width in enumerate(widths))
        out=[]
        for ri,row in enumerate(rows,1):
            if ri>1048576 or len(row)>16384: fail('表格超出 Excel 行列上限。')
            cells=[]
            for ci,c in enumerate(row):
                col='';x=ci+1
                while x: x,r=divmod(x-1,26);col=chr(65+r)+col
                value=str(c);ref=col+str(ri)
                # inlineStr prevents untrusted text from becoming an Excel formula.
                if spreadsheet_number(value):
                    cells.append('<c r="'+ref+'" t="n"><v>'+value+'</v></c>')
                else: cells.append('<c r="'+ref+'" t="inlineStr"><is><t xml:space="preserve">'+esc(value)+'</t></is></c>')
            lines=max((sum(max(1,math.ceil(display_width(line)/max(1,widths[ci]-2))) for line in str(c).split('\n')) for ci,c in enumerate(row)),default=1)
            out.append('<row r="'+str(ri)+'" ht="'+str(min(409,lines*16+4))+'" customHeight="1">'+''.join(cells)+'</row>')
        name='xl/worksheets/sheet'+str(n)+'.xml';parts[name]='<?xml version="1.0"?><worksheet xmlns="'+S+'"><sheetPr><pageSetUpPr fitToPage="1"/></sheetPr><cols>'+columns+'</cols><sheetData>'+''.join(out)+'</sheetData><pageMargins left="0.35" right="0.35" top="0.4" bottom="0.4" header="0.2" footer="0.2"/><pageSetup paperSize="9" orientation="portrait" fitToWidth="1" fitToHeight="0"/></worksheet>'
        over.append((name,'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'));sheets.append('<sheet name="Page '+str(n)+'" sheetId="'+str(n)+'" r:id="rId'+str(n)+'"/>');rels.append(('rId'+str(n),R+'/worksheet','worksheets/sheet'+str(n)+'.xml'))
    parts['xl/workbook.xml']='<?xml version="1.0"?><workbook xmlns="'+S+'" xmlns:r="'+R+'"><sheets>'+''.join(sheets)+'</sheets></workbook>'
    parts['xl/styles.xml']='<?xml version="1.0"?><styleSheet xmlns="'+S+'"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'
    over.append(('xl/styles.xml','application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml'));rels.append(('rIdStyles',R+'/styles','styles.xml'))
    parts['xl/_rels/workbook.xml.rels']=relationships(rels);parts['_rels/.rels']=relationships([('rId1',R+'/officeDocument','xl/workbook.xml')]);parts['[Content_Types].xml']=contenttypes(over);writezip(path,parts)
def odf_text(value):
    # ODF normalizes literal spaces/tabs/newlines inside text:p. Explicit elements
    # preserve leading/trailing/repeated whitespace and multiline cell values.
    parts=[]
    for token in re.findall(r' +|\t|\r\n|\r|\n|[^ \t\r\n]+',str(value)):
        if token.startswith(' '): parts.append('<text:s text:c="'+str(len(token))+'"/>')
        elif token=='\t': parts.append('<text:tab/>')
        elif token in ('\r','\n','\r\n'): parts.append('<text:line-break/>')
        else: parts.append(esc(token))
    return ''.join(parts)

def write_ods(m,path):
    rows=m.get('tables',[rows_for_page((m.get('pages') or [{}])[0])])[0]
    content='<?xml version="1.0"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet><table:table table:name="Sheet1">'+''.join('<table:table-row>'+''.join('<table:table-cell office:value-type="string"><text:p>'+odf_text(c)+'</text:p></table:table-cell>' for c in row)+'</table:table-row>' for row in rows)+'</table:table></office:spreadsheet></office:body></office:document-content>'
    writezip(path,{'mimetype':'application/vnd.oasis.opendocument.spreadsheet','content.xml':content,'META-INF/manifest.xml':'<?xml version="1.0"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>'},('mimetype',))
def write_pptx(m,path):
    pages=m.get('pages',[]) or [{}];first=pages[0];w=max(1,float(first.get('width',612)));h=max(1,float(first.get('height',792)));emu=12700
    parts={};over=[('ppt/presentation.xml','application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml'),('ppt/slideMasters/slideMaster1.xml','application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml'),('ppt/slideLayouts/slideLayout1.xml','application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml')]
    tree='<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
    ids=[];rels=[('rIdMaster',R+'/slideMaster','slideMasters/slideMaster1.xml')]
    for n,page in enumerate(pages,1):
        sx=w/max(1,float(page.get('width',w)));sy=h/max(1,float(page.get('height',h)));shapes=[]
        for j,b in enumerate(page.get('blocks',[]),2):
            x=max(0,float(b.get('x',48)))*sx;y=max(0,float(b.get('y',48)))*sy;bw=max(10,min(w-x,float(b.get('width',w-96))*sx));bh=max(16,float(b.get('height',20))*sy+6);size=max(6,min(96,float(b.get('fontSize',12))*sy))*100
            runs=''.join('<a:p><a:r><a:rPr lang="en-US" sz="'+str(round(size))+'"/><a:t>'+esc(line)+'</a:t></a:r><a:endParaRPr lang="en-US"/></a:p>' for line in str(b.get('text','')).split('\n'))
            shapes.append('<p:sp><p:nvSpPr><p:cNvPr id="'+str(j)+'" name="Text '+str(j)+'"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="'+str(round(x*emu))+'" y="'+str(round(y*emu))+'"/><a:ext cx="'+str(round(bw*emu))+'" cy="'+str(round(bh*emu))+'"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap="square" lIns="0" rIns="0" tIns="0" bIns="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>'+runs+'</p:txBody></p:sp>')
        name='ppt/slides/slide'+str(n)+'.xml';parts[name]='<?xml version="1.0"?><p:sld xmlns:p="'+P+'" xmlns:a="'+A+'" xmlns:r="'+R+'"><p:cSld>'+tree+''.join(shapes)+'</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>'
        parts['ppt/slides/_rels/slide'+str(n)+'.xml.rels']=relationships([('rId1',R+'/slideLayout','../slideLayouts/slideLayout1.xml')]);over.append((name,'application/vnd.openxmlformats-officedocument.presentationml.slide+xml'));ids.append('<p:sldId id="'+str(255+n)+'" r:id="rId'+str(n)+'"/>');rels.append(('rId'+str(n),R+'/slide','slides/slide'+str(n)+'.xml'))
    parts['ppt/presentation.xml']='<?xml version="1.0"?><p:presentation xmlns:p="'+P+'" xmlns:a="'+A+'" xmlns:r="'+R+'"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rIdMaster"/></p:sldMasterIdLst><p:sldIdLst>'+''.join(ids)+'</p:sldIdLst><p:sldSz cx="'+str(round(w*emu))+'" cy="'+str(round(h*emu))+'"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>'
    parts['ppt/_rels/presentation.xml.rels']=relationships(rels)
    parts['ppt/slideMasters/slideMaster1.xml']='<?xml version="1.0"?><p:sldMaster xmlns:p="'+P+'" xmlns:a="'+A+'" xmlns:r="'+R+'"><p:cSld>'+tree+'</p:spTree></p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>'
    parts['ppt/slideMasters/_rels/slideMaster1.xml.rels']=relationships([('rId1',R+'/slideLayout','../slideLayouts/slideLayout1.xml')])
    parts['ppt/slideLayouts/slideLayout1.xml']='<?xml version="1.0"?><p:sldLayout xmlns:p="'+P+'" xmlns:a="'+A+'" xmlns:r="'+R+'" type="blank" preserve="1"><p:cSld name="Blank">'+tree+'</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>'
    parts['ppt/slideLayouts/_rels/slideLayout1.xml.rels']=relationships([('rId1',R+'/slideMaster','../slideMasters/slideMaster1.xml')]);parts['_rels/.rels']=relationships([('rId1',R+'/officeDocument','ppt/presentation.xml')]);parts['[Content_Types].xml']=contenttypes(over);writezip(path,parts)
def write_epub(m,path):
    title=m.get('title','LocalShift');uid='urn:uuid:'+str(uuid.uuid4());body=''.join('<p>'+esc(p).replace('\n','<br/>')+'</p>' for p in paragraphs(m))
    doc='<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>'+esc(title)+'</title></head><body><h1>'+esc(title)+'</h1>'+body+'</body></html>'
    opf='<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">'+uid+'</dc:identifier><dc:title>'+esc(title)+'</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-01-01T00:00:00Z</meta></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="chapter"/></spine></package>'
    nav='<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">'+esc(title)+'</a></li></ol></nav></body></html>'
    writezip(path,{'mimetype':'application/epub+zip','META-INF/container.xml':'<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>','OEBPS/content.opf':opf,'OEBPS/chapter.xhtml':doc,'OEBPS/nav.xhtml':nav},('mimetype',))
def write_model(m,path,kind):
    if kind=='docx': write_docx(m,path)
    elif kind=='pptx': write_pptx(m,path)
    elif kind=='xlsx': write_xlsx(m,path)
    elif kind=='ods': write_ods(m,path)
    elif kind=='epub': write_epub(m,path)
    elif kind=='json':
        with open(path,'w',encoding='utf8') as f: json.dump(m,f,ensure_ascii=False)
    elif kind in ('txt','md'):
        with open(path,'w',encoding='utf8') as f: f.write('\n'.join(paragraphs(m))+'\n')
    elif kind=='html':
        with open(path,'w',encoding='utf8') as f: f.write('<!doctype html><html><head><meta charset="utf-8"><title>'+esc(m.get('title','LocalShift'))+'</title></head><body>'+''.join('<p>'+esc(p).replace('\n','<br>')+'</p>' for p in paragraphs(m))+'</body></html>')
    elif kind in ('csv','tsv'):
        rows=m.get('tables',[rows_for_page((m.get('pages') or [{}])[0])])[0]
        with open(path,'w',encoding='utf8',newline='') as f: csv.writer(f,delimiter='\t' if kind=='tsv' else ',').writerows(rows)
    else: fail('辅助程序不支持该目标格式。')

def spreadsheet_sheets(path):
    with zipfile.ZipFile(path) as z:
        zip_members(z);root=xml(z.read('xl/workbook.xml'))
        sheets=root.find('{'+S+'}sheets')
        if sheets is None: fail('工作簿没有工作表。')
        result=[]
        for index,sheet in enumerate(sheets,1):
            name=sheet.get('name','')
            # LibreOffice constructs all-sheet CSV paths from sheet names.
            if not name or any(c in name for c in '/\\') or any(ord(c)<32 for c in name): fail('工作表名称含路径或控制字符，无法安全导出 CSV。')
            label=re.sub(r'[^\w .()\-]', '_',name,flags=re.UNICODE).strip(' .')[:64] or 'Sheet'
            while len(label.encode('utf8'))>80: label=label[:-1]
            result.append({'name':name,'label':label,'index':index})
        if not result or len(result)>10000: fail('工作表数量无效或超过安全上限。')
        return result

def svg_dimensions(root):
    # A standalone export has no containing HTML viewport. Absolute root lengths
    # use CSS 96px/in; viewBox-only files use one CSS pixel per viewBox unit.
    # Do not guess percentages/font-relative sizes or a stylesheet cascade.
    number=r'[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?'
    factors={'':Decimal(1),'px':Decimal(1),'in':Decimal(96),'cm':Decimal(96)/Decimal('2.54'),'mm':Decimal(96)/Decimal('25.4'),'q':Decimal(96)/Decimal('101.6'),'pt':Decimal(96)/Decimal(72),'pc':Decimal(16)}
    def length(value):
        if value is None or value.strip().lower()=='auto': return None
        match=re.fullmatch(r'\s*('+number+r')\s*([A-Za-z]*)\s*',value)
        if not match or match[2].lower() not in factors: fail('SVG 画布尺寸须使用 px、in、cm、mm、Q、pt、pc 等绝对单位；不支持百分比、字体单位或计算表达式。')
        result=Decimal(match[1])*factors[match[2].lower()]
        if not result.is_finite() or result<=0: fail('SVG 画布尺寸必须为正有限数。')
        return result
    dimensions={key:root.get(key) for key in ('width','height')}
    inline=[];importance={}
    for declaration in root.get('style','').split(';'):
        key,separator,value=declaration.partition(':')
        if not separator:
            if declaration.strip(): inline.append(declaration)
            continue
        key=key.strip().lower()
        if key in dimensions:
            important=bool(re.search(r'!\s*important\s*$',value,re.I))
            if key not in importance or important or not importance[key]:
                dimensions[key]=re.sub(r'!\s*important\s*$','',value,flags=re.I).strip();importance[key]=important
        else: inline.append(declaration)
    for node in root.iter():
        if local(node).lower()=='style' and re.search(r'(?:^|[;{])\s*(?:width|height|min-width|max-width|min-height|max-height|inline-size|block-size)\s*:',node.text or '',re.I):
            fail('SVG 样式表中的画布尺寸需先展开为根元素的绝对 width/height。')
    box=None
    if root.get('viewBox') is not None:
        values=re.split(r'[\s,]+',root.get('viewBox').strip())
        if len(values)!=4 or any(not re.fullmatch(number,v) for v in values): fail('SVG viewBox 无效。')
        box=[Decimal(v) for v in values]
        if any(not v.is_finite() for v in box) or box[2]<=0 or box[3]<=0: fail('SVG viewBox 必须包含有限坐标和正尺寸。')
    width,height=length(dimensions['width']),length(dimensions['height'])
    if width is None and height is None:
        if box is None: fail('SVG 需要绝对 width/height 或有效 viewBox，无法推断独立画布。')
        width,height=box[2:]
    elif width is None or height is None:
        if box is None: fail('SVG 缺少一个画布尺寸且没有 viewBox 宽高比。')
        if width is None: width=height*box[2]/box[3]
        else: height=width*box[3]/box[2]
    if width>16384 or height>16384 or width*height>100_000_000: fail('SVG 画布超过 16384 / 一亿像素安全上限。')
    # An explicit viewBox prevents Draw's SVG importer from expanding a missing
    # viewport by a half CSS pixel on every edge. Keep its existing user space.
    if box is None: root.set('viewBox','0 0 '+str(width)+' '+str(height))
    root.set('width',str(width)+'px');root.set('height',str(height)+'px')
    if importance:
        inline.extend([key+':'+str(width if key=='width' else height)+'px !important' for key in importance])
        root.set('style',';'.join(inline))
    return {'width':float(width),'height':float(height),'pixelWidth':int(width.to_integral_value(rounding='ROUND_CEILING')),'pixelHeight':int(height.to_integral_value(rounding='ROUND_CEILING')),'dpi':96}

def sanitize_svg(source,output):
    data=open(source,'rb').read()
    if len(data)>32*1024*1024: fail('SVG 超过安全上限。')
    root=xml(data)
    if local(root).lower()!='svg': fail('输入不是 SVG。')
    for node in root.iter():
        tag=local(node).lower()
        if tag in ('script','foreignobject','iframe','object','embed','audio','video','animate','animatetransform','animatemotion','set','feimage','image'): fail('SVG 含脚本、嵌入资源或动态元素；请先导出为静态自包含 SVG。')
        if tag=='style':
            style=node.text or ''
            if '\\' in style or re.search(r'@import|expression\s*\(|javascript:',style,re.I): fail('SVG 样式含资源引用。')
            for ref in re.findall(r'url\s*\(\s*[\"\']?([^\)\"\']+)',style,re.I):
                if not ref.strip().startswith('#'): fail('SVG 样式含外部资源。')
        for key,value in node.attrib.items():
            key=key.split('}')[-1].lower()
            if key.startswith('on') or key in ('src','base'): fail('SVG 含事件或资源引用。')
            if key=='href' and not value.startswith('#'): fail('SVG 只允许文档内引用。')
            if re.search(r'@import|expression\s*\(|javascript:|file:|https?:|data:',value,re.I): fail('SVG 含外部资源。')
            # Local paint servers are safe; CSS escapes could obscure an external URL, so reject them.
            if '\\' in value: fail('SVG 含转义资源标记。')
            for ref in re.findall(r'url\s*\(\s*[\"\']?([^\)\"\']+)',value,re.I):
                if not ref.strip().startswith('#'): fail('SVG 仅允许文档内 paint server。')
    dimensions=svg_dimensions(root)
    ET.register_namespace('','http://www.w3.org/2000/svg')
    ET.ElementTree(root).write(output,encoding='utf-8',xml_declaration=True)
    return dimensions

def configure_office_fonts(executable, arguments):
    # The bundled headless build uses Fontconfig, not CoreText's system font list.
    # Its built-in font directory has Latin fonts but no CJK coverage. Keep the
    # document's font choices; expose installed fonts rather than rewriting text.
    profile=next((a.split('=',1)[1] for a in arguments if a.startswith('-env:UserInstallation=')),None)
    if profile is None: fail('Office 字体初始化缺少独立任务目录。')
    location=urlsplit(profile)
    if location.scheme!='file' or location.netloc not in ('','localhost'): fail('Office 任务目录无效。')
    job=pathlib.Path(unquote(location.path)).parent
    cache=job/'font-cache';cache.mkdir(parents=True,exist_ok=True)
    bundle=pathlib.Path(executable).resolve().parent.parent
    directories=[bundle/'Resources/fonts/truetype',pathlib.Path('/System/Library/Fonts'),pathlib.Path('/Library/Fonts'),pathlib.Path.home()/'Library/Fonts']
    directories=[p for p in directories if p.is_dir()]
    if not directories: fail('Office 转换没有可用字体目录。')
    config=job/'fonts.conf'
    config.write_text('<?xml version="1.0" encoding="UTF-8"?><fontconfig>'+''.join('<dir>'+esc(str(p))+'</dir>' for p in directories)+'<cachedir>'+esc(str(cache))+'</cachedir></fontconfig>',encoding='utf-8')
    os.environ['FONTCONFIG_FILE']=str(config)

def main():
    cmd=sys.argv[1]
    if cmd=='archive': archive(*sys.argv[2:])
    elif cmd=='extract': extract(*sys.argv[2:])
    elif cmd=='convert':
        source,output,kind=sys.argv[2:];write_model(read_model(source),output,kind)
    elif cmd=='svg': print(json.dumps(sanitize_svg(*sys.argv[2:]),ensure_ascii=False))
    elif cmd=='sheets': print(json.dumps(spreadsheet_sheets(*sys.argv[2:]),ensure_ascii=False))
    elif cmd=='office':
        configure_office_fonts(sys.argv[2],sys.argv[3:])
        # exec preserves Process cancellation; hard limits also stop malformed converter output.
        import resource
        limit=min(MAX_FILE,max(32*1024*1024,os.path.getsize(sys.argv[-1])*100))
        resource.setrlimit(resource.RLIMIT_FSIZE,(limit,limit))
        resource.setrlimit(resource.RLIMIT_CPU,(120,120))
        os.execv(sys.argv[2],sys.argv[2:])
    elif cmd=='checkzip':
        with zipfile.ZipFile(sys.argv[2]) as z:
            zip_members(z)
            for name in z.namelist():
                if name.lower().endswith('vbaproject.bin'): fail('离线转换拒绝宏文稿。')
                if name.endswith('.rels'):
                    for rel in xml(z.read(name)):
                        if rel.attrib.get('TargetMode')=='External' and not rel.attrib.get('Type','').endswith('/hyperlink'):
                            fail('Office 文稿含外部加载资源；请先嵌入资源。')
                elif name=='META-INF/manifest.xml':
                    xml(z.read(name))
    else: fail('未知辅助程序命令。')
if __name__=='__main__':
    try: main()
    except Exception as e:
        print('LocalShift: '+str(e),file=sys.stderr);sys.exit(1)
