import { describe, expect, it } from '@jest/globals';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(process.cwd(), '..');
const plugin = (...parts: string[]) =>
  fs.readFileSync(path.join(root, 'plugin', 'LightroomMCP.lrplugin', ...parts), 'utf8');

describe('AI batch plugin contract', () => {
  it('ships safe idempotency defaults and configurable Denoise amount', () => {
    const config = JSON.parse(plugin('config', 'pipeline.json')) as {
      denoise: { enabled: boolean; amount: number };
      skipProcessed: boolean;
      force: boolean;
    };

    expect(config.denoise).toMatchObject({ enabled: true, amount: 50 });
    expect(config.skipProcessed).toBe(true);
    expect(config.force).toBe(false);
  });

  it('uses genuine Enhance instead of traditional noise-reduction sliders', () => {
    const source = plugin('AiState.lua');

    expect(source).toContain('LrDevelopController.setEnhance("denoise", true, amount)');
    expect(source).toContain('panel.denoiseEnabled == true');
    expect(source).toContain('readyStableCount >= 3');
    expect(source).not.toContain('LuminanceSmoothing');
    expect(source).not.toContain('ColorNoiseReduction');
  });

  it('serializes job snapshots and uses unique temp files', () => {
    const source = plugin('BatchJobStore.lua');

    expect(source).toContain('local writeLocks = {}');
    expect(source).toContain('while writeLocks[path] do');
    expect(source).toContain('LrUUID.generateUUID() .. ".tmp"');
    expect(source).toContain('local previous = path .. ".previous"');
    expect(source).toContain('LrFileUtils.move(path, previous)');
    expect(source).toContain('readJsonFile(path) or readJsonFile(path .. ".previous")');
  });

  it('persists only the discovered Subject UUID, not per-job overrides', () => {
    const subject = plugin('SubjectPreset.lua');
    const config = plugin('PipelineConfig.lua');

    expect(subject).toContain('PipelineConfig.saveSubjectUuid(config.subjectPreset.uuid)');
    expect(subject).not.toContain('PipelineConfig.save(config)');
    expect(config).toContain('function PipelineConfig.saveSubjectUuid(uuid)');
  });

  it('uses a durable state index in addition to private metadata', () => {
    const pipeline = plugin('BatchPipeline.lua');
    const state = plugin('PipelineState.lua');

    expect(pipeline).toContain("local PipelineState = require 'PipelineState'");
    expect(pipeline).toContain('PipelineState.update(catalog, photo, values)');
    expect(state).toContain('pipeline-state.json');
    expect(state).toContain('catalogPath(catalog)');
    expect(state).toContain('photo.localIdentifier');
  });

  it('defines eight separate Landscape subcategory masks', () => {
    const source = plugin('LandscapePreset.lua');
    for (const id of [50001, 50002, 50003, 50004, 50005, 50006, 50007, 50008]) {
      expect(source).toContain(`= ${id}`);
    }
    expect(source).toContain('MaskSubCategoryID = id');
    expect(source).toContain('CorrectionName = "AUTO Landscape - " .. feature');
  });

  it('routes both menu profiles and the MCP start tool to the same backend', () => {
    const info = plugin('Info.lua');
    const fullMenu = plugin('MenuAIBatchPrepare.lua');
    const denoiseMenu = plugin('MenuAIBatchDenoise.lua');
    const common = plugin('MenuBatchCommon.lua');
    const handler = plugin('HandlerBatch.lua');
    const dispatch = plugin('PluginInfoProvider.lua');

    expect(info).toContain('LrExportMenuItems = {');
    expect(info).not.toContain('LrLibraryMenuItems = {');
    expect(fullMenu).toContain('{ profile = "full" }');
    expect(denoiseMenu).toContain('{ profile = "denoise-only" }');
    expect(common).toContain('HandlerBatch.start(args or {})');
    expect(common).toContain('HandlerBatch.status({ jobId = jobId })');
    expect(common).toContain('HandlerBatch.cancel({ jobId = state.lastJobId })');
    expect(handler).toContain("return pipeline().start(args or {})");
    expect(dispatch).toContain('lr_batch_pipeline = HandlerBatch.start');
  });

  it('keeps Denoise-only completion distinct from full-pipeline processing', () => {
    const pipeline = plugin('BatchPipeline.lua');

    expect(pipeline).toContain('config.profile ~= "denoise-only"');
    expect(pipeline).toContain('restorePhotoIds = photoIds(originalPhotos)');
    expect(pipeline).toContain('restoreActivePhotoId = originalActive and photoId(originalActive) or nil');
    expect(pipeline).toContain('restoreSelection(entry)');
  });
});
