#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path
import struct
import zlib


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_glb(data):
    require(len(data) >= 20, 'Truncated GLB header')
    magic, version, length = struct.unpack_from('<III', data)
    require(magic == 0x46546C67 and version == 2 and length == len(data), 'Invalid GLB 2 container')
    chunks = {}
    offset = 12
    while offset < length:
        require(offset + 8 <= length, 'Truncated GLB chunk')
        size, kind = struct.unpack_from('<II', data, offset)
        offset += 8
        require(size % 4 == 0 and offset + size <= length, 'Invalid GLB chunk length')
        require(kind not in chunks, 'Duplicate GLB chunk')
        chunks[kind] = data[offset:offset + size]
        offset += size
    doc = json.loads(chunks[0x4E4F534A])
    require(doc['asset']['version'] == '2.0', 'Unsupported glTF version')
    return doc, chunks[0x004E4942]


def view_bytes(doc, binary, index):
    view = doc['bufferViews'][index]
    require(view['buffer'] == 0, 'External buffers are not supported')
    start = view.get('byteOffset', 0)
    end = start + view['byteLength']
    require(0 <= start <= end <= len(binary), 'Buffer view outside GLB')
    return binary[start:end], view


def accessor(doc, binary, index, kind, component):
    acc = doc['accessors'][index]
    require(acc['type'] == kind and acc['componentType'] == component and not acc.get('sparse') and not acc.get('normalized'), 'Unsupported accessor encoding')
    count = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3}[kind]
    fmt = '<' + {5126: 'f', 5123: 'H'}[component] * count
    element_size = struct.calcsize(fmt)
    data, view = view_bytes(doc, binary, acc['bufferView'])
    start = acc.get('byteOffset', 0)
    stride = view.get('byteStride', element_size)
    require(stride >= element_size and start >= 0 and start + (acc['count'] - 1) * stride + element_size <= len(data), 'Accessor exceeds buffer view')
    result = [struct.unpack_from(fmt, data, start + i * stride) for i in range(acc['count'])]
    require(all(math.isfinite(v) for row in result for v in row), 'Non-finite mesh attribute')
    return result


def paeth(a, b, c):
    p = a + b - c
    distances = [abs(p - a), abs(p - b), abs(p - c)]
    return (a, b, c)[distances.index(min(distances))]


def decode_png(data):
    require(data[:8] == b'\x89PNG\r\n\x1a\n', 'Texture must be PNG')
    offset = 8
    compressed = bytearray()
    width = height = channels = None
    while offset < len(data):
        require(offset + 12 <= len(data), 'Truncated PNG chunk')
        size = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + size]
        require(offset + size + 12 <= len(data), 'PNG chunk exceeds image')
        crc = struct.unpack_from('>I', data, offset + 8 + size)[0]
        require(zlib.crc32(kind + body) == crc, 'PNG CRC mismatch')
        if kind == b'IHDR':
            width, height, bits, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', body)
            require(bits == 8 and color in (2, 6) and compression == filtering == interlace == 0, 'Only non-interlaced 8-bit RGB/RGBA PNG is supported')
            require(0 < width <= 4096 and 0 < height <= 4096, 'Unsupported texture dimensions')
            channels = 4 if color == 6 else 3
        elif kind == b'IDAT':
            compressed.extend(body)
        offset += size + 12
        if kind == b'IEND':
            break
    require(channels is not None, 'PNG has no IHDR')
    raw = zlib.decompress(compressed)
    stride = width * channels
    require(len(raw) == height * (stride + 1), 'PNG scanline size mismatch')
    result = bytearray()
    previous = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        filter_type = raw[start]
        require(filter_type <= 4, 'Unknown PNG filter')
        row = bytearray(raw[start + 1:start + stride + 1])
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            up = previous[x]
            upper_left = previous[x - channels] if x >= channels else 0
            prediction = (0, left, up, (left + up) // 2, paeth(left, up, upper_left))[filter_type]
            row[x] = (row[x] + prediction) & 255
        result.extend(row)
        previous = row
    return width, height, channels, result


def rotate(q, v):
    # Quaternion XYZW: v + 2*w*(q.xyz cross v) + 2*(q.xyz cross (q.xyz cross v)).
    x, y, z, w = q
    a, b, c = v
    tx, ty, tz = 2 * (y * c - z * b), 2 * (z * a - x * c), 2 * (x * b - y * a)
    return (a + w * tx + y * tz - z * ty, b + w * ty + z * tx - x * tz, c + w * tz + x * ty - y * tx)


def convert(data, texture_size=128):
    require(texture_size in (64, 128, 256), 'Texture size must be 64, 128 or 256')
    doc, binary = load_glb(data)
    require(not doc.get('skins') and not doc.get('animations'), 'This converter supports static meshes only')
    require(len(doc['nodes']) == len(doc['meshes']) == 1, 'Expected one mesh and one scene node')
    node = doc['nodes'][0]
    require(node.get('mesh') == 0 and not node.get('matrix') and not node.get('children'), 'Expected a single TRS mesh node')
    primitives = doc['meshes'][0]['primitives']
    require(len(primitives) == 1, 'Expected one material primitive')
    primitive = primitives[0]
    require(primitive.get('mode', 4) == 4 and not primitive.get('targets') and not primitive.get('extensions'), 'Expected uncompressed static triangles')
    attrs = primitive['attributes']
    positions = accessor(doc, binary, attrs['POSITION'], 'VEC3', 5126)
    normals = accessor(doc, binary, attrs['NORMAL'], 'VEC3', 5126)
    uvs = accessor(doc, binary, attrs['TEXCOORD_0'], 'VEC2', 5126)
    indices = [v[0] for v in accessor(doc, binary, primitive['indices'], 'SCALAR', 5123)]
    require(len(positions) == len(normals) == len(uvs) and len(indices) % 3 == 0 and max(indices) < len(positions), 'Invalid mesh topology')
    material = doc['materials'][primitive['material']]
    require(material.get('alphaMode', 'OPAQUE') == 'OPAQUE' and material.get('doubleSided'), 'Expected opaque, double-sided material')
    pbr = material['pbrMetallicRoughness']
    require(pbr.get('baseColorFactor', [1, 1, 1, 1]) == [1, 1, 1, 1], 'Base color factors are not supported')
    texture = doc['textures'][pbr['baseColorTexture']['index']]
    sampler = doc['samplers'][texture['sampler']]
    require(sampler.get('wrapS', 10497) == sampler.get('wrapT', 10497) == 10497, 'Expected repeat wrapping')
    image = doc['images'][texture['source']]
    require(image['mimeType'] == 'image/png', 'Expected embedded PNG')
    png, _ = view_bytes(doc, binary, image['bufferView'])
    width, height, channels, rgba = decode_png(png)
    require(width == height and width % texture_size == 0, 'Texture must resize by an integer factor')
    factor = width // texture_size
    require(factor >= 1, 'Texture upscaling is not supported')
    pixels = bytearray()
    for y in range(texture_size):
        for x in range(texture_size):
            rgb = []
            for channel in range(3):
                total = sum(rgba[((y * factor + dy) * width + x * factor + dx) * channels + channel] for dy in range(factor) for dx in range(factor))
                rgb.append((total + factor * factor // 2) // (factor * factor))
            r, g, b = rgb
            pixels.extend(struct.pack('<H', ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)))
    q = node.get('rotation', [0, 0, 0, 1])
    length = math.sqrt(sum(v * v for v in q))
    require(length > 0, 'Zero rotation quaternion')
    q = [v / length for v in q]
    scale = node.get('scale', [1, 1, 1])
    require(all(v > 0 for v in scale), 'Only positive node scales are supported')
    translation = node.get('translation', [0, 0, 0])
    positions = [tuple(v + t for v, t in zip(rotate(q, [p * s for p, s in zip(row, scale)]), translation)) for row in positions]
    normals = [rotate(q, [n / s for n, s in zip(row, scale)]) for row in normals]
    center = [(min(v[i] for v in positions) + max(v[i] for v in positions)) / 2 for i in range(3)]
    centered = [tuple(v - c for v, c in zip(row, center)) for row in positions]
    radius = max(math.sqrt(sum(v * v for v in row)) for row in centered)
    require(radius > 0, 'Empty model bounds')
    packed = []
    for p, n, uv in zip(centered, normals, uvs):
        normal_length = math.sqrt(sum(v * v for v in n))
        require(normal_length > 0 and all(0 <= v <= 1 for v in uv), 'Invalid normal or out-of-range UV')
        packed.append(struct.pack('<6h2H', *(round(v / radius * 16384) for v in p), *(round(v / normal_length * 16384) for v in n), *(round(v * 65535) for v in uv)))
    unique = {}
    remapped = []
    for index in indices:
        vertex = packed[index]
        if vertex not in unique:
            unique[vertex] = len(unique)
        remapped.append(unique[vertex])
    mesh = b''.join(unique) + struct.pack('<' + 'H' * len(remapped), *remapped)
    texture_offset = 32 + len(mesh)
    header = struct.pack('<4sHHIIHHIII', b'FUM1', 1, texture_size, len(unique), len(indices) // 3, 16, 0, 16384, texture_offset, texture_offset + len(pixels))
    return header + mesh + pixels


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--texture-size', type=int, default=128)
    args = parser.parse_args()
    data = convert(args.source.read_bytes(), args.texture_size)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)


if __name__ == '__main__':
    main()
