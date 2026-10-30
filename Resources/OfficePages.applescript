-- Only UUID-named documents belonging to this operation may be closed.
on closeOwned(uniqueStem)
    if application "Pages" is not running then return "LOCALSHIFT_PAGES_NOT_RUNNING"
    with timeout of 15 seconds
        tell application "Pages"
            repeat 4 times
                set foundOwned to false
                repeat with candidate in (get documents)
                    if (name of candidate) starts with uniqueStem then
                        close candidate saving no
                        set foundOwned to true
                        exit repeat
                    end if
                end repeat
                if not foundOwned then exit repeat
            end repeat
        end tell
    end timeout
    return "LOCALSHIFT_PAGES_CLEANED"
end closeOwned

on run argv
    set inputPath to item 1 of argv
    set outputPath to item 2 of argv
    set outputKind to item 3 of argv
    set uniqueStem to item 4 of argv
    set operationKind to "convert"
    if (count of argv) > 4 then set operationKind to item 5 of argv
    if operationKind is "cleanup" then return my closeOwned(uniqueStem)
    set ownedDocument to missing value
    -- LOCALSHIFT_TEST_BEFORE_EXPORT
    with timeout of 75 seconds
        tell application "Pages"
            try
                repeat 100 times
                    repeat with candidate in documents
                        if (name of candidate) starts with uniqueStem then
                            set ownedDocument to candidate
                            exit repeat
                        end if
                    end repeat
                    if ownedDocument is not missing value then exit repeat
                    delay 0.2
                end repeat
                if ownedDocument is missing value then error "Pages 未打开本任务临时文稿；请完成 Pages 首次启动提示或允许自动化。" number -2700
                -- LOCALSHIFT_TEST_DOCUMENT_READY
                if outputKind is "pages" then
                    save ownedDocument in (POSIX file outputPath)
                else if outputKind is "docx" then
                    export ownedDocument to (POSIX file outputPath) as Microsoft Word
                else if outputKind is "pdf" then
                    export ownedDocument to (POSIX file outputPath) as PDF
                else if outputKind is "txt" then
                    export ownedDocument to (POSIX file outputPath) as unformatted text
                else if outputKind is "epub" then
                    export ownedDocument to (POSIX file outputPath) as EPUB
                else
                    error "不支持的 Pages 导出格式。" number -2700
                end if
                -- LOCALSHIFT_TEST_AFTER_EXPORT
            on error errorMessage number errorNumber
                -- A lost export reply may still have completed the private file.
                -- The caller checks that file before considering one reconnect.
                error errorMessage number errorNumber
            end try
            try
                -- LOCALSHIFT_TEST_CLOSE
                close ownedDocument saving no
            on error closeMessage number closeNumber
                if closeNumber is -609 then return "LOCALSHIFT_PAGES_EXPORTED_CLOSE_609"
                error closeMessage number closeNumber
            end try
        end tell
    end timeout
    return "LOCALSHIFT_PAGES_EXPORTED"
end run
