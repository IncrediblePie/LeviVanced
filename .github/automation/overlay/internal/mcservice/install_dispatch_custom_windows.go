//go:build windows && amd64 && allowtrialinstall

// SPDX-License-Identifier: GPL-3.0-only
package mcservice

import (
	"context"
	"errors"
	"log"
	"path/filepath"
	"strings"
	"time"

	"github.com/liteldev/LeviLauncher/internal/apppath"
	"github.com/liteldev/LeviLauncher/internal/legacyextractor"
	"github.com/liteldev/LeviLauncher/internal/leviloader"
	"github.com/liteldev/LeviLauncher/internal/nativeinstall"
	"github.com/liteldev/LeviLauncher/internal/types"
	"github.com/liteldev/LeviLauncher/internal/utils"
	"github.com/wailsapp/wails/v3/pkg/application"
)

func useLegacyPreviewExtractor(isPreview bool) bool { return isPreview }

func InstallExtractMsixvc(ctx context.Context, name, folderName string, isPreview bool) string {
	if !useLegacyPreviewExtractor(isPreview) {
		return installExtractMsixvcNative(ctx, name, folderName, isPreview)
	}
	n := strings.TrimSpace(name)
	if n == "" {
		return "ERR_MSIXVC_NOT_SPECIFIED"
	}
	in := n
	if !filepath.IsAbs(in) {
		if dir, err := apppath.InstallersDir(); err == nil && dir != "" {
			in = filepath.Join(dir, n+".msixvc")
		}
	}
	if !utils.FileExists(in) {
		return "ERR_MSIXVC_NOT_FOUND"
	}
	vdir, err := apppath.InstancesDir()
	if err != nil || strings.TrimSpace(vdir) == "" {
		return "ERR_ACCESS_VERSIONS_DIR"
	}
	folder := strings.TrimSpace(folderName)
	if folder == "" || folder == "." || folder == ".." || filepath.Base(folder) != folder || strings.ContainsAny(folder, "<>:\"/\\|?*") {
		return "ERR_INVALID_FOLDER_NAME"
	}
	out := filepath.Join(vdir, folder)
	log.Printf("LeviVanced: Preview MSIXVC installation uses legacy extractor v0.3.13 (SHA256 %s)", legacyextractor.CoreSHA256)
	err = legacyextractor.Install(ctx, in, out, nativeinstall.Options{
		Prepare: func(staging string) error { return leviloader.EnsureForVersion(ctx, staging) },
		Progress: func(p nativeinstall.Progress) {
			application.Get().Event.Emit(EventExtractProgress, types.ExtractProgress{
				Dir: out, Bytes: p.FileCurrent, TotalBytes: p.FileTotal,
				GlobalCurrent: p.Current, GlobalTotal: p.Total, CurrentFile: p.File, Ts: time.Now().UnixMilli(),
			})
		},
	})
	if err != nil {
		code := "ERR_NATIVE_MSIXVC"
		var failure *legacyextractor.Error
		if errors.As(err, &failure) {
			code = failure.Code
		}
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			code = "ERR_CANCELED"
		}
		log.Printf("LeviVanced: legacy Preview extraction failed: %v", err)
		application.Get().Event.Emit(EventExtractError, code)
		return code
	}
	application.Get().Event.Emit(EventExtractDone, out)
	return ""
}
